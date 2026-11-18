#!/usr/bin/env bash
set -euo pipefail

PERSIST_DIR="/opt/data/.hermes"
RUNTIME_DIR="/var/lib/hermes/.hermes"
VENV_PY="/opt/hermes/.venv/bin/python"

export HERMES_HOME="${RUNTIME_DIR}"
export HERMES_WRITE_SAFE_ROOT="/var/lib/hermes:/opt/data"
export HERMES_DOCKER_EXEC_AS_ROOT=1
export HERMES_ALLOW_ROOT_GATEWAY=1
export HERMES_GATEWAY_LOCK_DIR="/tmp/hermes-locks"
export HOME="/root"

mkdir -p /tmp/hermes-locks

for BASE_DIR in "${PERSIST_DIR}" "${RUNTIME_DIR}"; do
  mkdir -p \
    "${BASE_DIR}/backups" \
    "${BASE_DIR}/cron" \
    "${BASE_DIR}/sessions" \
    "${BASE_DIR}/logs" \
    "${BASE_DIR}/logs/gateways" \
    "${BASE_DIR}/hooks" \
    "${BASE_DIR}/memories" \
    "${BASE_DIR}/skills/.hub" \
    "${BASE_DIR}/skins" \
    "${BASE_DIR}/plans" \
    "${BASE_DIR}/workspace" \
    "${BASE_DIR}/home" \
    "${BASE_DIR}/pairing" \
    "${BASE_DIR}/platforms/pairing"

  for PROFILE in dev-builder qa-researcher; do
    mkdir -p \
      "${BASE_DIR}/profiles/${PROFILE}/memories" \
      "${BASE_DIR}/profiles/${PROFILE}/sessions" \
      "${BASE_DIR}/profiles/${PROFILE}/skills/.hub" \
      "${BASE_DIR}/profiles/${PROFILE}/skins" \
      "${BASE_DIR}/profiles/${PROFILE}/logs" \
      "${BASE_DIR}/profiles/${PROFILE}/plans" \
      "${BASE_DIR}/profiles/${PROFILE}/workspace" \
      "${BASE_DIR}/profiles/${PROFILE}/cron" \
      "${BASE_DIR}/profiles/${PROFILE}/home"
  done
done

# Link /root/.hermes to the local POSIX runtime directory (backed by GCS sync)
rm -rf /root/.hermes
ln -s "${RUNTIME_DIR}" /root/.hermes

# Boot restore: copy persistent state from GCSFuse (/opt/data/.hermes) -> local POSIX (/var/lib/hermes/.hermes)
# and validate any restored SQLite databases.
"${VENV_PY}" - <<'PY'
import os
import shutil
import sqlite3
import stat
from pathlib import Path

persist_dir = Path("/opt/data/.hermes")
runtime_dir = Path("/var/lib/hermes/.hermes")

SKIP_DIRS = {"cache", "logs", "tmp", ".git", "__pycache__", "state", "runtime"}
SKIP_EXACT = {
    "gateway.lock",
    "gateway.pid",
    "gateway.sock",
    "gateway.sock.path",
    "gateway_state.json",
    "gateway.heartbeat",
    ".tick.lock",
    "ticker_heartbeat",
    "ticker_last_success",
}
SKIP_SUFFIXES = (
    ".db-journal",
    ".db-wal",
    ".db-shm",
    "-journal",
    "-wal",
    "-shm",
    ".tmp",
    ".lock",
    ".sock",
)
ROOT_FILES = ("config.yaml", "SOUL.md", "auth.json", ".env")
ROOT_TREES = (
    "memories",
    "skills",
    "skins",
    "plans",
    "workspace",
    "backups",
    "hooks",
    "sessions",
    "cron",
    "pairing",
    "platforms",
    "profiles",
)


def should_skip_file(name: str) -> bool:
    return name in SKIP_EXACT or name.endswith(SKIP_SUFFIXES)


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    try:
        shutil.copystat(src, dst)
    except OSError:
        pass


for fname in ROOT_FILES:
    src = persist_dir / fname
    if src.is_file():
        try:
            copy_file(src, runtime_dir / fname)
        except OSError as exc:
            print(f"[start_hermes] Warning: failed to restore {fname}: {exc}", flush=True)

for tree in ROOT_TREES:
    src_root = persist_dir / tree
    if not src_root.exists():
        continue
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel_dir = Path(dirpath).relative_to(persist_dir)
        for fname in filenames:
            if should_skip_file(fname):
                continue
            src = Path(dirpath) / fname
            dst = runtime_dir / rel_dir / fname
            try:
                if stat.S_ISREG(src.lstat().st_mode):
                    copy_file(src, dst)
            except OSError as exc:
                print(f"[start_hermes] Warning: failed to restore {rel_dir / fname}: {exc}", flush=True)

# Validate every restored .db file; quarantine/delete corrupted DBs in both runtime and persist dirs.
for db_path in list(runtime_dir.rglob("*.db")):
    if not db_path.is_file():
        continue
    rel = db_path.relative_to(runtime_dir)
    ok = False
    try:
        conn = sqlite3.connect(str(db_path), timeout=5.0)
        try:
            qc = conn.execute("PRAGMA quick_check").fetchall()
            _ = conn.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
            ok = (qc == [("ok",)])
        finally:
            conn.close()
    except Exception as exc:
        print(f"[start_hermes] Corrupted DB detected at {rel}: {exc}", flush=True)
        ok = False

    if not ok:
        print(f"[start_hermes] Removing corrupted DB {rel} so Hermes can reinitialize cleanly", flush=True)
        db_path.unlink(missing_ok=True)
        persist_db = persist_dir / rel
        persist_db.unlink(missing_ok=True)
        for sidecar in ("-journal", "-wal", "-shm"):
            Path(f"{db_path}{sidecar}").unlink(missing_ok=True)
            Path(f"{persist_db}{sidecar}").unlink(missing_ok=True)
PY

# Seed main config.yaml on first boot, or ensure GCP_PROJECT_ID and platforms.api_server stay updated
"${VENV_PY}" - <<'PY'
import os
from pathlib import Path
from ruamel.yaml import YAML

runtime_dir = Path("/var/lib/hermes/.hermes")
project_id = os.environ.get("GCP_PROJECT_ID", "").strip()
yaml = YAML()
yaml.preserve_quotes = True

main_cfg_path = runtime_dir / "config.yaml"
if not main_cfg_path.exists():
    raw = Path("/app/default_config.yaml").read_text(encoding="utf-8")
    raw = raw.replace("${GCP_PROJECT_ID}", project_id)
    main_cfg_path.write_text(raw, encoding="utf-8")
else:
    data = yaml.load(main_cfg_path.read_text(encoding="utf-8")) or {}
    default_data = yaml.load(Path("/app/default_config.yaml").read_text(encoding="utf-8")) or {}
    if project_id:
        vertex = data.setdefault("vertex", {})
        if not vertex.get("project_id") or vertex.get("project_id") == "${GCP_PROJECT_ID}":
            vertex["project_id"] = project_id
        vertex.setdefault("region", "global")
    if "platforms" not in data and "platforms" in default_data:
        data["platforms"] = default_data["platforms"]
    elif isinstance(data.get("platforms"), dict) and "api_server" not in data["platforms"]:
        data["platforms"]["api_server"] = default_data["platforms"]["api_server"]
    with main_cfg_path.open("w", encoding="utf-8") as fh:
        yaml.dump(data, fh)

profiles = {
    "dev-builder": "glm-5.3-flash",
    "qa-researcher": "minimax-m3.1-flash",
}

for profile_name, model_name in profiles.items():
    cfg_path = runtime_dir / "profiles" / profile_name / "config.yaml"
    if not cfg_path.exists():
        cfg = {
            "_config_version": 53,
            "model": {
                "default": model_name,
                "provider": "custom",
                "base_url": "https://ollama.com/v1",
                "api_key_env": "OLLAMA_API_KEY",
            },
            "vertex": {
                "project_id": project_id,
                "region": "global",
            },
            "fallback_providers": [
                {
                    "provider": "vertex",
                    "model": "google/gemini-3-flash-preview",
                    "on_capabilities": ["vision", "video", "audio"],
                }
            ],
            "auxiliary": {
                "vision": {
                    "provider": "vertex",
                    "model": "google/gemini-3-flash-preview",
                }
            },
            "database": {
                "journal_mode": "delete",
                "auto_prune": False,
            },
            "sessions": {
                "auto_prune": False,
            },
        }
        with cfg_path.open("w", encoding="utf-8") as fh:
            yaml.dump(cfg, fh)
PY

# Derive deterministic dashboard HMAC secret so sessions survive restarts
DASH_USER="${HERMES_DASHBOARD_USER:-admin}"
DASH_PASS="${HERMES_DASHBOARD_PASSWORD:-}"
API_KEY="${HERMES_API_KEY:-${API_SERVER_KEY:-}}"

if [ -n "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]; then
  DASH_SECRET="${HERMES_DASHBOARD_BASIC_AUTH_SECRET}"
else
  DASH_SECRET="$("${VENV_PY}" - <<'PY'
import hashlib, os
s = ":".join(
    os.environ.get(k, "")
    for k in ("HERMES_DASHBOARD_PASSWORD", "HERMES_API_KEY", "GCP_PROJECT_ID")
)
print(hashlib.sha256(s.encode("utf-8")).hexdigest())
PY
)"
fi

export API_SERVER_ENABLED="true"
export API_SERVER_HOST="0.0.0.0"
export API_SERVER_PORT="8000"
export API_SERVER_KEY="${API_KEY}"
export VERTEX_PROJECT_ID="${GCP_PROJECT_ID:-}"
export VERTEX_REGION="global"
export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${DASH_USER}"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${DASH_PASS}"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="${DASH_SECRET}"

# Sync profile-scoped .env files (multiplex mode reads each profile's .env)
"${VENV_PY}" - <<'PY'
import os
from pathlib import Path

runtime_dir = Path("/var/lib/hermes/.hermes")
env_paths = [
    runtime_dir / ".env",
    runtime_dir / "profiles" / "dev-builder" / ".env",
    runtime_dir / "profiles" / "qa-researcher" / ".env",
]

managed_keys = [
    ("OLLAMA_API_KEY", os.environ.get("OLLAMA_API_KEY", "")),
    ("API_SERVER_KEY", os.environ.get("API_SERVER_KEY", "")),
    ("API_SERVER_ENABLED", "true"),
    ("API_SERVER_HOST", "0.0.0.0"),
    ("API_SERVER_PORT", "8000"),
    ("VERTEX_PROJECT_ID", os.environ.get("VERTEX_PROJECT_ID", "")),
    ("VERTEX_REGION", "global"),
    ("HERMES_DASHBOARD_BASIC_AUTH_USERNAME", os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_USERNAME", "admin")),
    ("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD", os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD", "")),
    ("HERMES_DASHBOARD_BASIC_AUTH_SECRET", os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_SECRET", "")),
]
managed_names = {k for k, _ in managed_keys}

for env_path in env_paths:
    existing_lines = []
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped == "# OPENAI_BASE_URL=https://ollama.com/v1":
                continue
            key_part = stripped.split("=", 1)[0] if "=" in stripped and not stripped.startswith("#") else None
            if key_part in managed_names:
                continue
            existing_lines.append(line)

    out_lines = list(existing_lines)
    # Satisfy hermes doctor's _has_provider_env_config hint without polluting OPENAI_BASE_URL
    out_lines.append("# OPENAI_BASE_URL=https://ollama.com/v1")
    for k, v in managed_keys:
        if v:
            out_lines.append(f"{k}={v}")

    env_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    os.chmod(env_path, 0o600)
PY

# Run config schema migrations and sync bundled skills
"${VENV_PY}" /opt/hermes/scripts/docker_config_migrate.py || true
"${VENV_PY}" /opt/hermes/tools/skills_sync.py || true

# Ensure Skills Hub dir exists and disable unconfigured image_gen CLI toolset so hermes doctor stays clean
mkdir -p "${RUNTIME_DIR}/skills/.hub"
"${VENV_PY}" - <<'PY'
import sys
sys.path.insert(0, "/opt/hermes")
try:
    from hermes_cli.config import load_config, save_config
    from hermes_cli.tools_config_mcp import _apply_toolset_change

    cfg = load_config() or {}
    _apply_toolset_change(cfg, "cli", ["image_gen"], "disable")
    save_config(cfg)
except Exception as exc:
    print(f"[start_hermes] Warning: could not configure CLI toolsets: {exc}", flush=True)
PY

# Write transactional GCS online backup sync helper (local POSIX -> GCSFuse)
cat <<'PY' > /tmp/hermes_gcs_sync.py
import argparse
import os
import shutil
import signal
import sqlite3
import stat
import sys
import tempfile
import time
from pathlib import Path

RUNTIME_DIR = Path("/var/lib/hermes/.hermes")
PERSIST_DIR = Path("/opt/data/.hermes")

SKIP_DIRS = {"cache", "logs", "tmp", ".git", "__pycache__", "state", "runtime"}
SKIP_EXACT = {
    "gateway.lock",
    "gateway.pid",
    "gateway.sock",
    "gateway.sock.path",
    "gateway_state.json",
    "gateway.heartbeat",
    ".tick.lock",
    "ticker_heartbeat",
    "ticker_last_success",
}
SKIP_SUFFIXES = (
    ".db-journal",
    ".db-wal",
    ".db-shm",
    "-journal",
    "-wal",
    "-shm",
    ".tmp",
    ".lock",
    ".sock",
)

_STOP = False


def _on_signal(_signum, _frame):
    global _STOP
    _STOP = True


def should_skip_file(name: str) -> bool:
    return name in SKIP_EXACT or name.endswith(SKIP_SUFFIXES)


def sync_db(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="hermes-db-bak-", suffix=".db", dir="/tmp")
    os.close(fd)
    tmp_path = Path(tmp_name)
    src_conn = None
    dst_conn = None
    try:
        src_conn = sqlite3.connect(str(src), timeout=10.0)
        dst_conn = sqlite3.connect(str(tmp_path), timeout=10.0)
        src_conn.backup(dst_conn)
        dst_conn.close()
        dst_conn = None
        src_conn.close()
        src_conn = None
        shutil.copyfile(tmp_path, dst)
    finally:
        if dst_conn is not None:
            try:
                dst_conn.close()
            except Exception:
                pass
        if src_conn is not None:
            try:
                src_conn.close()
            except Exception:
                pass
        tmp_path.unlink(missing_ok=True)


def sync_once(last_synced: dict[str, tuple[int, int]] | None = None) -> None:
    if not RUNTIME_DIR.exists():
        return
    for dirpath, dirnames, filenames in os.walk(RUNTIME_DIR):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel_dir = Path(dirpath).relative_to(RUNTIME_DIR)
        for fname in filenames:
            if should_skip_file(fname):
                continue
            src = Path(dirpath) / fname
            rel_key = str(rel_dir / fname) if str(rel_dir) != "." else fname
            dst = PERSIST_DIR / rel_key
            try:
                st = src.lstat()
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            sig = (st.st_mtime_ns, st.st_size)
            if last_synced is not None:
                if last_synced.get(rel_key) == sig:
                    continue
            else:
                try:
                    dst_st = dst.stat()
                    if dst_st.st_size == st.st_size and int(dst_st.st_mtime) >= int(st.st_mtime) and not fname.endswith(".db"):
                        continue
                except OSError:
                    pass
            try:
                if fname.endswith(".db"):
                    sync_db(src, dst)
                else:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(src, dst)
                if last_synced is not None:
                    last_synced[rel_key] = sig
            except OSError as exc:
                print(f"[gcs_sync] Warning syncing {rel_key}: {exc}", file=sys.stderr, flush=True)
            except Exception as exc:
                print(f"[gcs_sync] Error syncing {rel_key}: {exc}", file=sys.stderr, flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--once", action="store_true")
    group.add_argument("--daemon", type=int, metavar="INTERVAL_SEC")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    if args.once:
        sync_once(None)
        return

    last_synced: dict[str, tuple[int, int]] = {}
    interval = max(2, args.daemon)
    while not _STOP:
        sync_once(last_synced)
        for _ in range(interval):
            if _STOP:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
PY

# Initial sync of seeded config/skills to persistent GCS storage, then start continuous sync daemon
"${VENV_PY}" /tmp/hermes_gcs_sync.py --once || true
"${VENV_PY}" /tmp/hermes_gcs_sync.py --daemon 10 &
SYNC_PID=$!

cleanup() {
  echo "[start_hermes] Shutting down..." >&2
  for pid in "${PROXY_PID:-}" "${DASH_PID:-}" "${HERMES_PID:-}"; do
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done
  for pid in "${PROXY_PID:-}" "${DASH_PID:-}" "${HERMES_PID:-}"; do
    if [ -n "${pid}" ]; then
      wait "${pid}" 2>/dev/null || true
    fi
  done
  if [ -n "${SYNC_PID:-}" ] && kill -0 "${SYNC_PID}" 2>/dev/null; then
    kill -TERM "${SYNC_PID}" 2>/dev/null || true
    wait "${SYNC_PID}" 2>/dev/null || true
  fi
  echo "[start_hermes] Flushing final state to GCS..." >&2
  "${VENV_PY}" /tmp/hermes_gcs_sync.py --once || true
}
trap cleanup SIGTERM SIGINT

# Start the multiplexed Hermes Gateway (serves OpenAI-compatible API Server on 8000)
hermes gateway run &
HERMES_PID=$!

# Start the Hermes Web Dashboard / Remote Desktop Backend (serves port 9119)
hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build &
DASH_PID=$!

# Start async aiohttp reverse proxy on $PORT (8080) supporting SSE streaming, WebSockets, and multi-value headers
"${VENV_PY}" - <<'PY' &
import asyncio
import os
import aiohttp
from aiohttp import web
from multidict import CIMultiDict

PORT = int(os.environ.get("PORT", "8080"))
API_ORIGIN = "http://127.0.0.1:8000"
DASH_ORIGIN = "http://127.0.0.1:9119"
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def pick_upstream(path: str) -> str:
    if (
        path == "/v1"
        or path.startswith("/v1/")
        or path.startswith("/p/")
        or path == "/webhooks"
        or path.startswith("/webhooks/")
        or path == "/health"
        or path.startswith("/health/")
    ):
        return API_ORIGIN
    return DASH_ORIGIN


def filter_request_headers(request: web.Request) -> CIMultiDict:
    headers: CIMultiDict = CIMultiDict()
    for k, v in request.headers.items():
        lk = k.lower()
        if lk in HOP_BY_HOP or lk in ("content-length", "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-protocol"):
            continue
        headers.add(k, v)
    if "X-Forwarded-Proto" not in headers:
        headers["X-Forwarded-Proto"] = request.headers.get("X-Forwarded-Proto", "https")
    if "X-Forwarded-Host" not in headers and request.host:
        headers["X-Forwarded-Host"] = request.host
    return headers


async def handle_websocket(request: web.Request, upstream_base: str) -> web.StreamResponse:
    ws_base = upstream_base.replace("http://", "ws://", 1).replace("https://", "wss://", 1)
    upstream_url = f"{ws_base}{request.rel_url}"
    raw_protocols = request.headers.get("Sec-WebSocket-Protocol", "")
    protocols = [p.strip() for p in raw_protocols.split(",") if p.strip()]
    headers = filter_request_headers(request)

    session: aiohttp.ClientSession = request.app["client_session"]
    try:
        upstream_ws = await session.ws_connect(
            upstream_url,
            headers=headers,
            protocols=protocols or (),
            heartbeat=20.0,
            max_msg_size=0,
        )
    except Exception as exc:
        return web.Response(status=502, text=f"Upstream WebSocket error: {exc}")

    selected_protocols = (upstream_ws.protocol,) if upstream_ws.protocol else ()
    client_ws = web.WebSocketResponse(protocols=selected_protocols, heartbeat=20.0, max_msg_size=0)
    await client_ws.prepare(request)

    async def forward_client_to_upstream() -> None:
        async for msg in client_ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                await upstream_ws.send_str(msg.data)
            elif msg.type == aiohttp.WSMsgType.BINARY:
                await upstream_ws.send_bytes(msg.data)
            elif msg.type == aiohttp.WSMsgType.CLOSE:
                await upstream_ws.close(code=msg.data or 1000, message=msg.extra.encode() if isinstance(msg.extra, str) else b"")
                break

    async def forward_upstream_to_client() -> None:
        async for msg in upstream_ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                await client_ws.send_str(msg.data)
            elif msg.type == aiohttp.WSMsgType.BINARY:
                await client_ws.send_bytes(msg.data)
            elif msg.type == aiohttp.WSMsgType.CLOSE:
                await client_ws.close(code=msg.data or 1000, message=msg.extra.encode() if isinstance(msg.extra, str) else b"")
                break

    try:
        tasks = [
            asyncio.create_task(forward_client_to_upstream()),
            asyncio.create_task(forward_upstream_to_client()),
        ]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            _ = task.exception()
    finally:
        if not upstream_ws.closed:
            await upstream_ws.close()
        if not client_ws.closed:
            await client_ws.close()
    return client_ws


async def handle_http(request: web.Request) -> web.StreamResponse:
    upstream_base = pick_upstream(request.path)
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await handle_websocket(request, upstream_base)

    upstream_url = f"{upstream_base}{request.rel_url}"
    headers = filter_request_headers(request)
    body = await request.read() if request.can_read_body else None
    session: aiohttp.ClientSession = request.app["client_session"]

    last_exc = None
    for attempt in range(4):
        try:
            async with session.request(
                request.method,
                upstream_url,
                headers=headers,
                data=body,
                allow_redirects=False,
            ) as resp:
                out = web.StreamResponse(status=resp.status, reason=resp.reason)
                for k, v in resp.headers.items():
                    if k.lower() not in HOP_BY_HOP and k.lower() != "content-length":
                        out.headers.add(k, v)
                await out.prepare(request)
                async for chunk in resp.content.iter_any():
                    await out.write(chunk)
                await out.write_eof()
                return out
        except aiohttp.ClientConnectorError as exc:
            last_exc = exc
            await asyncio.sleep(0.35)
        except Exception as exc:
            return web.Response(status=502, text=f"Upstream proxy error: {exc}")

    return web.Response(status=502, text=f"Upstream unavailable: {last_exc}")


async def on_startup(app: web.Application) -> None:
    timeout = aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=3600)
    connector = aiohttp.TCPConnector(limit=256)
    app["client_session"] = aiohttp.ClientSession(
        timeout=timeout,
        connector=connector,
        auto_decompress=False,
    )


async def on_cleanup(app: web.Application) -> None:
    session = app.get("client_session")
    if session is not None:
        await session.close()


def main() -> None:
    app = web.Application(client_max_size=128 * 1024 * 1024)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_route("*", "/{tail:.*}", handle_http)
    web.run_app(app, host="0.0.0.0", port=PORT, access_log=None)


if __name__ == "__main__":
    main()
PY
PROXY_PID=$!

# Background readiness wait + hermes doctor diagnostic check
(
  for _ in $(seq 1 180); do
    if "${VENV_PY}" -c '
import socket
for port in (8000, 9119):
    with socket.create_connection(("127.0.0.1", port), timeout=1):
        pass
' 2>/dev/null; then
      echo "[start_hermes] Ports 8000 and 9119 are listening; running hermes doctor..."
      hermes doctor || true
      break
    fi
    sleep 2
  done
) &

wait -n "${HERMES_PID}" "${DASH_PID}" "${PROXY_PID}"
EXIT_CODE=$?
cleanup
exit "${EXIT_CODE}"
