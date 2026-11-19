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
export HF_HOME="/opt/hermes/hf-cache"
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
    "${BASE_DIR}/platforms/pairing" \
    "${BASE_DIR}/webapp"

  chmod 700 "${BASE_DIR}/webapp"

  for PROFILE in mixtape-agent creative-tv dev-builder qa-researcher; do
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
    "webapp",
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

webapp_dir = runtime_dir / "webapp"
if webapp_dir.exists():
    try:
        os.chmod(webapp_dir, 0o700)
        for p in webapp_dir.rglob("*"):
            os.chmod(p, 0o700 if p.is_dir() else 0o600)
    except OSError as exc:
        print(f"[start_hermes] Warning: could not tighten webapp permissions: {exc}", flush=True)

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

def migrate_tts_to_gemini(cfg: dict) -> bool:
    tts_cfg = cfg.get("tts")
    if not isinstance(tts_cfg, dict):
        return False
    updated = False
    if not tts_cfg.get("provider") or tts_cfg.get("provider") in ("edge", "piper"):
        tts_cfg["provider"] = "gemini"
        updated = True
    gemini_cfg = tts_cfg.get("gemini")
    if not isinstance(gemini_cfg, dict):
        gemini_cfg = {}
        tts_cfg["gemini"] = gemini_cfg
        updated = True
    if not gemini_cfg.get("model") or gemini_cfg.get("model") == "gemini-2.5-flash-preview-tts":
        gemini_cfg["model"] = "gemini-3.8-flash-lite-tts"
        updated = True
    if not gemini_cfg.get("voice"):
        gemini_cfg["voice"] = "Kore"
        updated = True
    if "audio_tags" not in gemini_cfg:
        gemini_cfg["audio_tags"] = False
        updated = True
    if "piper" in tts_cfg:
        tts_cfg.pop("piper", None)
        updated = True
    return updated


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
    elif isinstance(data.get("platforms"), dict):
        if "api_server" not in data["platforms"] and "api_server" in (default_data.get("platforms") or {}):
            data["platforms"]["api_server"] = default_data["platforms"]["api_server"]
        else:
            api_srv = data["platforms"].setdefault("api_server", {})
            api_extra = api_srv.setdefault("extra", {})
            routes = api_extra.setdefault("model_routes", {})
            default_routes = (
                (default_data.get("platforms") or {})
                .get("api_server", {})
                .get("extra", {})
                .get("model_routes", {})
            )
            for alias, route_cfg in default_routes.items():
                if alias not in routes:
                    routes[alias] = route_cfg
    if "webapp" in default_data:
        data["webapp"] = default_data["webapp"]
    for section_key in ("stt", "tts", "voice"):
        if section_key in default_data:
            if section_key not in data or not isinstance(data.get(section_key), dict):
                data[section_key] = default_data[section_key]
    migrate_tts_to_gemini(data)
    if "stt" in default_data and isinstance(data.get("stt"), dict):
        data["stt"].setdefault("enabled", True)
        data["stt"].setdefault("provider", "local")
        local_cfg = data["stt"].setdefault("local", {})
        local_cfg.setdefault("model", "base")
        local_cfg.setdefault("device", "cpu")
        local_cfg.setdefault("compute_type", "int8")
        local_cfg.setdefault("vad", True)
        local_cfg.setdefault("unload_after_idle_seconds", 300)
    if "voice" in default_data and isinstance(data.get("voice"), dict):
        data["voice"]["client_direct"] = False
    with main_cfg_path.open("w", encoding="utf-8") as fh:
        yaml.dump(data, fh)

profiles = {
    "mixtape-agent": {
        "model": {
            "default": "minimax-m3.1-flash",
            "provider": "custom",
            "base_url": "https://ollama.com/v1",
            "api_key_env": "OLLAMA_API_KEY",
        },
        "fallback_providers": [
            {
                "provider": "vertex",
                "model": "google/gemini-3-flash-preview",
                "on_capabilities": ["vision", "video", "audio"],
            }
        ],
    },
    "creative-tv": {
        "model": {
            "default": "google/gemini-3-flash-preview",
            "provider": "vertex",
        },
        "fallback_providers": [
            {
                "provider": "custom",
                "model": "minimax-m3.1-flash",
                "base_url": "https://ollama.com/v1",
                "api_key_env": "OLLAMA_API_KEY",
            }
        ],
    },
    "dev-builder": {
        "model": {
            "default": "glm-5.3-flash",
            "provider": "custom",
            "base_url": "https://ollama.com/v1",
            "api_key_env": "OLLAMA_API_KEY",
        },
        "fallback_providers": [
            {
                "provider": "vertex",
                "model": "google/gemini-3-flash-preview",
                "on_capabilities": ["vision", "video", "audio"],
            }
        ],
    },
    "qa-researcher": {
        "model": {
            "default": "minimax-m3.1-flash",
            "provider": "custom",
            "base_url": "https://ollama.com/v1",
            "api_key_env": "OLLAMA_API_KEY",
        },
        "fallback_providers": [
            {
                "provider": "vertex",
                "model": "google/gemini-3-flash-preview",
                "on_capabilities": ["vision", "video", "audio"],
            }
        ],
    },
}

default_data_for_profiles = yaml.load(Path("/app/default_config.yaml").read_text(encoding="utf-8")) or {}

for profile_name, spec in profiles.items():
    cfg_path = runtime_dir / "profiles" / profile_name / "config.yaml"
    if not cfg_path.exists():
        cfg = {
            "_config_version": 53,
            "model": spec["model"],
            "vertex": {
                "project_id": project_id,
                "region": "global",
            },
            "fallback_providers": spec["fallback_providers"],
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
        for section_key in ("stt", "tts", "voice"):
            if section_key in default_data_for_profiles:
                cfg[section_key] = default_data_for_profiles[section_key]
        with cfg_path.open("w", encoding="utf-8") as fh:
            yaml.dump(cfg, fh)
    else:
        prof_data = yaml.load(cfg_path.read_text(encoding="utf-8")) or {}
        changed = False
        for section_key in ("stt", "tts", "voice"):
            if section_key in default_data_for_profiles and (
                section_key not in prof_data or not isinstance(prof_data.get(section_key), dict)
            ):
                prof_data[section_key] = default_data_for_profiles[section_key]
                changed = True
        if migrate_tts_to_gemini(prof_data):
            changed = True
        if changed:
            with cfg_path.open("w", encoding="utf-8") as fh:
                yaml.dump(prof_data, fh)

# Seed SOUL.md for root (default) and sub-profiles if missing, and refresh Lens Grove skill
import shutil

soul_targets = [
    (Path("/app/profiles/default/SOUL.md"), runtime_dir / "SOUL.md"),
    *[
        (Path(f"/app/profiles/{name}/SOUL.md"), runtime_dir / "profiles" / name / "SOUL.md")
        for name in profiles
    ],
]
for src_soul, dst_soul in soul_targets:
    if src_soul.is_file() and not dst_soul.exists():
        dst_soul.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src_soul, dst_soul)

grove_skill_src = Path("/app/skills/lens-grove-uploader/SKILL.md")
if grove_skill_src.is_file():
    for skill_dst in (
        runtime_dir / "skills" / "lens-grove-uploader" / "SKILL.md",
        runtime_dir / "profiles" / "mixtape-agent" / "skills" / "lens-grove-uploader" / "SKILL.md",
    ):
        skill_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(grove_skill_src, skill_dst)

adk_skill_src = Path("/app/skills/creative-adk-peers/SKILL.md")
if adk_skill_src.is_file():
    adk_skill_dst = runtime_dir / "skills" / "creative-adk-peers" / "SKILL.md"
    adk_skill_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(adk_skill_src, adk_skill_dst)
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
root_env = runtime_dir / ".env"
env_paths = [
    root_env,
    runtime_dir / "profiles" / "mixtape-agent" / ".env",
    runtime_dir / "profiles" / "creative-tv" / ".env",
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
    ("MIXTAPE_GROVE_SIGNER_KEY", os.environ.get("MIXTAPE_GROVE_SIGNER_KEY", "")),
    ("PIXELS_ADK_URL", os.environ.get("PIXELS_ADK_URL", "")),
    ("DEAR_CREATIVE_ADK_URL", os.environ.get("DEAR_CREATIVE_ADK_URL", "")),
]
root_only_keys = [
    ("TELEGRAM_BOT_TOKEN", os.environ.get("TELEGRAM_BOT_TOKEN", "")),
    ("DISCORD_BOT_TOKEN", os.environ.get("DISCORD_BOT_TOKEN", "")),
]
managed_names = {k for k, _ in managed_keys} | {k for k, _ in root_only_keys}

def _read_dotenv_key(path: Path, keys: tuple[str, ...]) -> str:
    if not path.is_file():
        return ""
    found: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        k, v = stripped.split("=", 1)
        k = k.strip()
        if k in keys:
            val = v.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                val = val[1:-1]
            if val:
                found[k] = val
    for k in keys:
        if found.get(k):
            return found[k]
    return ""


env_gemini_key = (os.environ.get("GEMINI_API_KEY", "") or os.environ.get("GOOGLE_API_KEY", "")).strip()
root_saved_gemini_key = _read_dotenv_key(root_env, ("GEMINI_API_KEY", "GOOGLE_API_KEY"))
shared_gemini_key = env_gemini_key or root_saved_gemini_key

for env_path in env_paths:
    has_gemini_in_existing = False
    existing_lines = []
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped == "# OPENAI_BASE_URL=https://ollama.com/v1":
                continue
            key_part = stripped.split("=", 1)[0].strip() if "=" in stripped and not stripped.startswith("#") else None
            if key_part in managed_names:
                continue
            if env_gemini_key and key_part == "GEMINI_API_KEY":
                continue
            if key_part in ("GEMINI_API_KEY", "GOOGLE_API_KEY"):
                val_part = stripped.split("=", 1)[1].strip().strip('"').strip("'")
                if val_part:
                    has_gemini_in_existing = True
            existing_lines.append(line)

    out_lines = list(existing_lines)
    # Satisfy hermes doctor's _has_provider_env_config hint without polluting OPENAI_BASE_URL
    out_lines.append("# OPENAI_BASE_URL=https://ollama.com/v1")
    keys_for_path = list(managed_keys)
    if env_path == root_env:
        keys_for_path.extend(root_only_keys)
    for k, v in keys_for_path:
        if v:
            out_lines.append(f"{k}={v}")
    if env_gemini_key:
        out_lines.append(f"GEMINI_API_KEY={env_gemini_key}")
    elif shared_gemini_key and env_path != root_env and not has_gemini_in_existing:
        out_lines.append(f"GEMINI_API_KEY={shared_gemini_key}")

    env_path.parent.mkdir(parents=True, exist_ok=True)
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
PROFILE_NAMES = ("mixtape-agent", "creative-tv", "dev-builder", "qa-researcher")
_GEMINI_KEYS = ("GEMINI_API_KEY", "GOOGLE_API_KEY")

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


def _read_dotenv_map(path: Path) -> tuple[list[str], dict[str, str]]:
    if not path.is_file():
        return [], {}
    lines = path.read_text(encoding="utf-8").splitlines()
    values: dict[str, str] = {}
    for raw_line in lines:
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        k, v = stripped.split("=", 1)
        k = k.strip()
        if k in _GEMINI_KEYS:
            val = v.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                val = val[1:-1]
            if val:
                values[k] = val
    return lines, values


def mirror_root_gemini_key(state: dict[str, str]) -> None:
    _, root_vals = _read_dotenv_map(RUNTIME_DIR / ".env")
    root_key = root_vals.get("GEMINI_API_KEY") or root_vals.get("GOOGLE_API_KEY") or ""
    if not root_key:
        return
    last_mirrored = state.get("last_mirrored", "")
    for profile in PROFILE_NAMES:
        p_env = RUNTIME_DIR / "profiles" / profile / ".env"
        try:
            old_text = p_env.read_text(encoding="utf-8") if p_env.is_file() else ""
        except OSError:
            continue
        lines, prof_vals = _read_dotenv_map(p_env)
        cur_gemini = prof_vals.get("GEMINI_API_KEY", "")
        cur_google = prof_vals.get("GOOGLE_API_KEY", "")
        should_update = (not cur_gemini and not cur_google) or (bool(last_mirrored) and cur_gemini == last_mirrored)
        if not should_update:
            continue
        new_lines: list[str] = []
        replaced = False
        for line in lines:
            stripped = line.strip()
            key_part = stripped.split("=", 1)[0].strip() if "=" in stripped and not stripped.startswith("#") else None
            if key_part == "GEMINI_API_KEY":
                if not replaced:
                    new_lines.append(f"GEMINI_API_KEY={root_key}")
                    replaced = True
                continue
            new_lines.append(line)
        if not replaced:
            new_lines.append(f"GEMINI_API_KEY={root_key}")
        new_text = "\n".join(new_lines) + "\n"
        if new_text != old_text:
            try:
                p_env.parent.mkdir(parents=True, exist_ok=True)
                p_env.write_text(new_text, encoding="utf-8")
                os.chmod(p_env, 0o600)
            except OSError as exc:
                print(f"[gcs_sync] Warning mirroring GEMINI_API_KEY to {profile}: {exc}", file=sys.stderr, flush=True)
    state["last_mirrored"] = root_key


def sync_once(
    last_synced: dict[str, tuple[int, int]] | None = None,
    mirror_state: dict[str, str] | None = None,
) -> None:
    if not RUNTIME_DIR.exists():
        return
    if mirror_state is None:
        mirror_state = {}
    mirror_root_gemini_key(mirror_state)
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
    mirror_state: dict[str, str] = {}
    interval = max(2, args.daemon)
    while not _STOP:
        sync_once(last_synced, mirror_state)
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
  for pid in "${PROXY_PID:-}" "${VOICE_PID:-}" "${HERMES_PID:-}"; do
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done
  for pid in "${PROXY_PID:-}" "${VOICE_PID:-}" "${HERMES_PID:-}"; do
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

# Start the multiplexed Hermes Gateway (serves OpenAI API on 8000 + browser-hosted Hermes Desktop Webapp on 9120)
hermes gateway run &
HERMES_PID=$!

# Start the bilingual Voice Bridge (Faster-Whisper STT + wake-word gate + Google Gemini TTS on 8001)
"${VENV_PY}" /app/voice_bridge.py &
VOICE_PID=$!

# Start async aiohttp reverse proxy on $PORT (8080) supporting SSE streaming, WebSockets, and multi-value headers
"${VENV_PY}" - <<'PY' &
import asyncio
import os
import aiohttp
from aiohttp import web
from multidict import CIMultiDict

PORT = int(os.environ.get("PORT", "8080"))
API_ORIGIN = "http://127.0.0.1:8000"
VOICE_ORIGIN = "http://127.0.0.1:8001"
DASH_ORIGIN = "http://127.0.0.1:9120"
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
    if path == "/v1/voice" or path.startswith("/v1/voice/"):
        return VOICE_ORIGIN
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
for port in (8000, 8001, 9120):
    with socket.create_connection(("127.0.0.1", port), timeout=1):
        pass
' 2>/dev/null; then
      echo "[start_hermes] Ports 8000, 8001, and 9120 are listening; running hermes doctor..."
      hermes doctor || true
      break
    fi
    sleep 2
  done
) &

wait -n "${HERMES_PID}" "${VOICE_PID}" "${PROXY_PID}"
EXIT_CODE=$?
cleanup
exit "${EXIT_CODE}"
