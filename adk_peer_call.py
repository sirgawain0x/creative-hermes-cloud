#!/usr/bin/env python3
"""Bridge CLI for Google ADK peer agents (Creative Pixels & Dear Creative)."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


DEFAULT_PIXELS_ADK_URL = "https://creative-director-3ortoh2aiq-ue.a.run.app"
DEFAULT_DEAR_CREATIVE_ADK_URL = "https://adam-3ortoh2aiq-uk.a.run.app"
DEFAULT_DEAR_CREATIVE_APP_URL = "https://news.creativeplatform.xyz"
METADATA_IDENTITY_URL = (
    "http://metadata.google.internal/computeMetadata/v1/instance/"
    "service-accounts/default/identity"
)


def fetch_cloud_run_id_token(audience: str) -> str | None:
    """Fetch a Cloud Run OIDC identity token from the GCP metadata server."""
    aud = audience.strip().rstrip("/")
    if not aud:
        return None
    query = urllib.parse.urlencode({"audience": aud, "format": "full"})
    req = urllib.request.Request(
        f"{METADATA_IDENTITY_URL}?{query}",
        headers={"Metadata-Flavor": "Google"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            token = resp.read().decode("utf-8", errors="replace").strip()
            return token or None
    except Exception:
        return None


def resolve_peer_base_url(peer: str) -> str:
    if peer == "pixels":
        return (os.environ.get("PIXELS_ADK_URL") or DEFAULT_PIXELS_ADK_URL).strip().rstrip("/")
    if peer == "dear-creative":
        return (
            (os.environ.get("DEAR_CREATIVE_ADK_URL") or DEFAULT_DEAR_CREATIVE_ADK_URL)
            .strip()
            .rstrip("/")
        )
    raise ValueError(f"Unsupported peer: {peer}")


def http_json(
    method: str,
    url: str,
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 60,
) -> tuple[int, Any, str]:
    req_headers: dict[str, str] = {"Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    data: bytes | None = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                parsed = raw
            return resp.status, parsed, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = raw
        return exc.code, parsed, raw
    except Exception as exc:
        return 0, {"error": str(exc)}, str(exc)


def auth_headers_for(base_url: str) -> dict[str, str]:
    headers: dict[str, str] = {"Content-Type": "application/json"}
    token = fetch_cloud_run_id_token(base_url)
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def discover_apps(base_url: str, headers: dict[str, str]) -> tuple[int, list[str], Any]:
    status, parsed, _ = http_json("GET", f"{base_url}/list-apps", headers=headers, timeout=20)
    apps: list[str] = []
    if isinstance(parsed, list):
        apps = [str(item) for item in parsed if isinstance(item, str) and item.strip()]
    elif isinstance(parsed, dict) and isinstance(parsed.get("apps"), list):
        apps = [str(item) for item in parsed["apps"] if isinstance(item, str) and item.strip()]
    return status, apps, parsed


def extract_reply_text(events: Any) -> str:
    items = events if isinstance(events, list) else [events]
    chunks: list[str] = []
    for ev in items:
        if not isinstance(ev, dict):
            continue
        content = ev.get("content")
        if not isinstance(content, dict):
            continue
        role = content.get("role")
        if role and role != "model":
            continue
        parts = content.get("parts")
        if not isinstance(parts, list):
            continue
        for part in parts:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                text = part["text"].strip()
                if text:
                    chunks.append(text)
    return "\n\n".join(chunks)


def resolve_app_candidates(
    peer: str,
    explicit_app_name: str | None,
    base_url: str,
    headers: dict[str, str],
) -> tuple[list[str], list[str]]:
    if explicit_app_name and explicit_app_name.strip():
        name = explicit_app_name.strip()
        return [name], [name]

    if peer == "pixels":
        env_name = (os.environ.get("DIRECTOR_ADK_APP_NAME") or "").strip()
        if env_name:
            return [env_name], [env_name]
        _, discovered, _ = discover_apps(base_url, headers)
        candidates = [*discovered]
        for fallback in ("agent", "creative-director-ai"):
            if fallback not in candidates:
                candidates.append(fallback)
        return candidates, discovered

    env_name = (os.environ.get("DEAR_CREATIVE_ADK_APP_NAME") or "").strip()
    if env_name:
        return [env_name], [env_name]
    _, discovered, _ = discover_apps(base_url, headers)
    candidates = [*discovered]
    for fallback in ("adam", "agent"):
        if fallback not in candidates:
            candidates.append(fallback)
    return candidates, discovered


def cmd_list_apps(args: argparse.Namespace) -> int:
    base_url = resolve_peer_base_url(args.peer)
    headers = auth_headers_for(base_url)
    status, apps, raw = discover_apps(base_url, headers)
    ok = 200 <= status < 300
    print(
        json.dumps(
            {
                "ok": ok,
                "peer": args.peer,
                "url": base_url,
                "status": status,
                "apps": apps,
                **({"detail": raw} if not ok else {}),
            },
            indent=2,
        )
    )
    return 0 if ok else 1


def cmd_run(args: argparse.Namespace) -> int:
    base_url = resolve_peer_base_url(args.peer)
    headers = auth_headers_for(base_url)
    user_id = args.user_id.strip() or "hermes-orchestrator"
    session_id = (args.session_id or f"hermes-{int(time.time() * 1000)}").strip()
    message = args.message.strip()
    if not message:
        print(json.dumps({"ok": False, "error": "--message is required"}))
        return 2

    candidates, discovered = resolve_app_candidates(args.peer, args.app_name, base_url, headers)
    last_error: dict[str, Any] = {}

    for app_name in candidates:
        sess_url = (
            f"{base_url}/apps/{urllib.parse.quote(app_name, safe='')}"
            f"/users/{urllib.parse.quote(user_id, safe='')}"
            f"/sessions/{urllib.parse.quote(session_id, safe='')}"
        )
        s_status, s_body, _ = http_json("POST", sess_url, body={"state": {}}, headers=headers, timeout=30)
        if s_status == 404 and not args.app_name:
            last_error = {"stage": "session", "status": s_status, "appName": app_name, "detail": s_body}
            continue
        if s_status not in (200, 201, 400, 409):
            print(
                json.dumps(
                    {
                        "ok": False,
                        "peer": args.peer,
                        "url": base_url,
                        "appName": app_name,
                        "discoveredApps": discovered,
                        "stage": "session",
                        "status": s_status,
                        "detail": s_body,
                    },
                    indent=2,
                )
            )
            return 1

        r_status, r_body, _ = http_json(
            "POST",
            f"{base_url}/run",
            body={
                "appName": app_name,
                "userId": user_id,
                "sessionId": session_id,
                "newMessage": {"role": "user", "parts": [{"text": message}]},
            },
            headers=headers,
            timeout=120,
        )
        if r_status == 404 and not args.app_name:
            last_error = {"stage": "run", "status": r_status, "appName": app_name, "detail": r_body}
            continue
        if not (200 <= r_status < 300):
            print(
                json.dumps(
                    {
                        "ok": False,
                        "peer": args.peer,
                        "url": base_url,
                        "appName": app_name,
                        "stage": "run",
                        "status": r_status,
                        "detail": r_body,
                    },
                    indent=2,
                )
            )
            return 1

        events = r_body if isinstance(r_body, list) else [r_body]
        reply_text = extract_reply_text(events)
        print(
            json.dumps(
                {
                    "ok": True,
                    "peer": args.peer,
                    "appName": app_name,
                    "sessionId": session_id,
                    "replyText": reply_text,
                    "events": events,
                },
                indent=2,
            )
        )
        return 0

    print(
        json.dumps(
            {
                "ok": False,
                "peer": args.peer,
                "url": base_url,
                "candidates": candidates,
                "discoveredApps": discovered,
                **last_error,
            },
            indent=2,
        )
    )
    return 1


def cmd_check_article(args: argparse.Namespace) -> int:
    slug = args.slug.strip()
    if not slug:
        print(json.dumps({"ok": False, "error": "--slug is required"}))
        return 2
    app_url = (os.environ.get("DEAR_CREATIVE_APP_URL") or DEFAULT_DEAR_CREATIVE_APP_URL).strip().rstrip("/")
    target = f"{app_url}/api/posts/{urllib.parse.quote(slug, safe='')}/full"
    status, parsed, _ = http_json("GET", target, timeout=20)
    if status == 200:
        pricing_mode = "free"
    elif status == 402:
        pricing_mode = "paid"
    else:
        pricing_mode = "unknown"
    ok = status in (200, 402)
    print(
        json.dumps(
            {
                "ok": ok,
                "slug": slug,
                "url": target,
                "status": status,
                "pricingMode": pricing_mode,
                "body": parsed,
            },
            indent=2,
        )
    )
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="adk-peer-call",
        description="Call Creative Pixels and Dear Creative Google ADK peer agents from Hermes.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list-apps", help="Discover ADK apps exposed by a peer service.")
    p_list.add_argument("--peer", choices=["pixels", "dear-creative"], required=True)
    p_list.set_defaults(func=cmd_list_apps)

    p_run = sub.add_parser("run", help="Run a prompt against an ADK peer agent.")
    p_run.add_argument("--peer", choices=["pixels", "dear-creative"], required=True)
    p_run.add_argument("--message", required=True)
    p_run.add_argument("--user-id", default="hermes-orchestrator")
    p_run.add_argument("--session-id", default="")
    p_run.add_argument("--app-name", default="")
    p_run.set_defaults(func=cmd_run)

    p_article = sub.add_parser(
        "check-article",
        help="Check whether a Dear Creative article slug is Free ($0.00) or Paid ($1.00 USDC).",
    )
    p_article.add_argument("--slug", required=True)
    p_article.set_defaults(func=cmd_check_article)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
