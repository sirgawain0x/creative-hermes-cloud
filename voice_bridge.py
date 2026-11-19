#!/usr/bin/env python3
"""Bilingual Voice Bridge (Faster-Whisper STT + Wake-Word Gate + Google Gemini TTS) on 127.0.0.1:8001."""

from __future__ import annotations

import asyncio
import base64
import binascii
import hmac
import json
import logging
import math
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unicodedata
from pathlib import Path
from typing import Any

import aiohttp
from aiohttp import web
from faster_whisper import WhisperModel

logging.basicConfig(
    level=os.environ.get("VOICE_BRIDGE_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [voice_bridge] %(levelname)s %(message)s",
)
logger = logging.getLogger("voice_bridge")

HOST = os.environ.get("VOICE_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOICE_BRIDGE_PORT", "8001"))
HERMES_API_BASE = os.environ.get("HERMES_API_BASE", "http://127.0.0.1:8000").rstrip("/")
STT_MODEL_NAME = os.environ.get("VOICE_STT_MODEL", "base")
GEMINI_API_BASE = os.environ.get("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta").rstrip("/")
GEMINI_TTS_MODEL = os.environ.get("VOICE_GEMINI_MODEL", "gemini-3.8-flash-lite-tts")
DEFAULT_EN_VOICE = os.environ.get("VOICE_DEFAULT_EN", "Kore")
DEFAULT_ES_VOICE = os.environ.get("VOICE_DEFAULT_ES", "Kore")
DEFAULT_CHAT_MODEL = os.environ.get("VOICE_DEFAULT_MODEL", "hermes-agent")
GEMINI_PREBUILT_VOICES = frozenset(
    {
        "Zephyr",
        "Puck",
        "Charon",
        "Kore",
        "Fenrir",
        "Leda",
        "Orus",
        "Aoede",
        "Callirrhoe",
        "Autonoe",
        "Enceladus",
        "Iapetus",
        "Umbriel",
        "Algieba",
        "Despina",
        "Erinome",
        "Algenib",
        "Rasalgethi",
        "Laomedeia",
        "Achernar",
        "Alnilam",
        "Schedar",
        "Gacrux",
        "Pulcherrima",
        "Achird",
        "Zubenelgenubi",
        "Vindemiatrix",
        "Sadachbia",
        "Sadaltager",
        "Sulafat",
    }
)
_GEMINI_VOICE_CANONICAL = {voice.lower(): voice for voice in GEMINI_PREBUILT_VOICES}
_CUSTOM_GEMINI_VOICE_RE = re.compile(r"^voice(?:key)?_[a-zA-Z0-9_-]{4,128}$")
_GEMINI_KEY_CACHE: dict[Path, tuple[int, int, str]] = {}

_MIME_TO_SUFFIX = {
    "audio/wav": ".wav",
    "audio/wave": ".wav",
    "audio/x-wav": ".wav",
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/webm": ".webm",
    "video/webm": ".webm",
    "audio/ogg": ".ogg",
    "audio/opus": ".ogg",
    "audio/mp4": ".m4a",
    "audio/m4a": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/flac": ".flac",
}

_WAKE_WORD_RE = re.compile(r"\b(hermes|ermes|hermis|hermies|creative)\b", re.IGNORECASE)
_LEADING_WAKE_RE = re.compile(
    r"^\s*(?:(?:hey|hi|hello|ok|okay|yo|oye|hola|buenos\s+dias|buenas\s+tardes|buenas\s+noches)\s*,?\s*)?"
    r"(?:hermes|ermes|hermis|hermies|creative)(?:\s*(?:ai|swarm))?\s*[,:;\-–—.!?]*\s*",
    re.IGNORECASE,
)
_SPANISH_MARKERS = {
    "hola",
    "como",
    "estas",
    "que",
    "por",
    "para",
    "gracias",
    "quiero",
    "necesito",
    "dime",
    "buenos",
    "buenas",
    "dias",
    "tardes",
    "noches",
    "espanol",
    "español",
    "puedes",
    "donde",
    "cuando",
    "quien",
    "ayuda",
    "favor",
    "en",
    "el",
    "un",
    "una",
    "los",
    "las",
    "del",
    "es",
    "soy",
    "eres",
    "esta",
    "estoy",
    "pero",
    "porque",
    "responde",
    "frase",
    "corta",
    "habla",
    "cuentame",
    "busca",
    "sobre",
    "cancion",
    "hoy",
    "ayer",
    "manana",
    "algo",
    "todo",
    "nada",
    "bien",
    "muy",
    "mas",
    "aqui",
    "hacer",
    "tengo",
    "tienes",
    "vamos",
}
_PROFILE_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$")


def _get_expected_api_key() -> str:
    return (os.environ.get("API_SERVER_KEY") or os.environ.get("HERMES_API_KEY") or "").strip()


def _strip_accents(text: str) -> str:
    nfd = unicodedata.normalize("NFD", text)
    return "".join(ch for ch in nfd if unicodedata.category(ch) != "Mn")


def _check_auth(request: web.Request) -> web.Response | None:
    expected = _get_expected_api_key()
    if not expected:
        return web.json_response({"error": "Voice bridge API key not configured"}, status=503)
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return web.json_response({"error": "Unauthorized"}, status=401)
    token = auth[7:].strip()
    if not token or not hmac.compare_digest(token, expected):
        return web.json_response({"error": "Unauthorized"}, status=401)
    return None


def _is_truthy(val: Any, default: bool = False) -> bool:
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return bool(val)
    if isinstance(val, str):
        return val.strip().lower() in {"1", "true", "yes", "on"}
    return default


def _wrap_pcm16_wav(pcm_bytes: bytes, *, sample_rate: int = 16000, channels: int = 1, sample_width: int = 2) -> bytes:
    byte_rate = sample_rate * channels * sample_width
    block_align = channels * sample_width
    bits_per_sample = sample_width * 8
    data_size = len(pcm_bytes)
    riff_size = 36 + data_size
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        riff_size,
        b"WAVE",
        b"fmt ",
        16,
        1,  # PCM format
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
        b"data",
        data_size,
    )
    return header + pcm_bytes


def _decode_audio_payload(payload: dict[str, Any]) -> tuple[bytes, str]:
    raw_b64 = (payload.get("audio_base64") or "").strip()
    if not raw_b64:
        raise ValueError("audio_base64 is required")

    inferred_mime = (payload.get("mime_type") or "").split(";", 1)[0].strip().lower()
    if raw_b64.startswith("data:") and "," in raw_b64:
        header, encoded = raw_b64.split(",", 1)
        if not inferred_mime:
            inferred_mime = header[5:].split(";", 1)[0].strip().lower()
    else:
        encoded = raw_b64

    try:
        audio_bytes = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError(f"Invalid base64 audio payload: {exc}") from exc

    if not audio_bytes:
        raise ValueError("Audio payload is empty")

    raw_pcm = _is_truthy(payload.get("raw_pcm"), default=False)
    if raw_pcm or inferred_mime in {"audio/pcm", "audio/l16"}:
        sample_rate = max(8000, min(48000, int(payload.get("sample_rate") or 16000)))
        channels = max(1, min(2, int(payload.get("channels") or 1)))
        sample_width = int(payload.get("sample_width") or 2)
        if sample_width not in (1, 2, 4):
            sample_width = 2
        audio_bytes = _wrap_pcm16_wav(
            audio_bytes,
            sample_rate=sample_rate,
            channels=channels,
            sample_width=sample_width,
        )
        return audio_bytes, ".wav"

    suffix = _MIME_TO_SUFFIX.get(inferred_mime, ".wav")
    return audio_bytes, suffix


def _normalize_explicit_language(raw_lang: Any) -> str | None:
    if not isinstance(raw_lang, str) or not raw_lang.strip():
        return None
    norm = raw_lang.strip().lower()
    if norm == "es" or norm.startswith("es-") or norm == "spanish" or norm == "español":
        return "es"
    if norm == "en" or norm.startswith("en-") or norm == "english":
        return "en"
    return None


def detect_language(
    text: str,
    *,
    explicit_language: Any = None,
    whisper_language: str | None = None,
) -> str:
    explicit = _normalize_explicit_language(explicit_language)
    if explicit:
        return explicit
    if whisper_language and whisper_language.lower().startswith("es"):
        return "es"

    lowered = text.lower()
    if any(ch in lowered for ch in ("¿", "¡", "ñ", "á", "é", "í", "ó", "ú", "ü")):
        return "es"

    words = re.findall(r"[a-zñ]+", _strip_accents(lowered))
    hits = sum(1 for w in words if w in _SPANISH_MARKERS)
    if hits >= 2 or (len(words) <= 3 and hits >= 1):
        return "es"
    return "en"


def check_wake_word(transcript: str) -> tuple[bool, str]:
    normalized = _strip_accents(transcript)
    matched = bool(_WAKE_WORD_RE.search(normalized))
    if not matched:
        return False, transcript.strip()
    cleaned = _LEADING_WAKE_RE.sub("", normalized).strip()
    if not cleaned:
        return True, transcript.strip()
    # Strip the matching prefix length from the original transcript to preserve original accents/casing.
    prefix_match = _LEADING_WAKE_RE.match(normalized)
    if prefix_match:
        remainder = transcript[prefix_match.end():].strip()
        return True, remainder or transcript.strip()
    return True, transcript.strip()


def clean_text_for_tts(text: str) -> str:
    cleaned = re.sub(r"```[\s\S]*?```", " ", text)
    cleaned = re.sub(r"`([^`]+)`", r"\1", cleaned)
    cleaned = re.sub(r"!\[[^\]]*\]\([^)]+\)", "", cleaned)
    cleaned = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", cleaned)
    cleaned = re.sub(r"^#{1,6}\s*", "", cleaned, flags=re.MULTILINE)
    cleaned = re.sub(r"[*_~]+", "", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def _read_dotenv_gemini_key(path: Path) -> str:
    try:
        st = path.stat()
    except OSError:
        _GEMINI_KEY_CACHE.pop(path, None)
        return ""
    cached = _GEMINI_KEY_CACHE.get(path)
    if cached is not None and cached[0] == st.st_mtime_ns and cached[1] == st.st_size:
        return cached[2]
    found: dict[str, str] = {}
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            stripped = raw_line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            k, v = stripped.split("=", 1)
            k = k.strip()
            if k in ("GEMINI_API_KEY", "GOOGLE_API_KEY"):
                val = v.strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                    val = val[1:-1]
                if val:
                    found[k] = val
    except OSError:
        return ""
    value = found.get("GEMINI_API_KEY") or found.get("GOOGLE_API_KEY") or ""
    _GEMINI_KEY_CACHE[path] = (st.st_mtime_ns, st.st_size, value)
    return value


def _get_gemini_api_key() -> str:
    direct = (os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or "").strip()
    if direct:
        return direct
    hermes_home = Path(os.environ.get("HERMES_HOME", "/var/lib/hermes/.hermes"))
    for candidate in (hermes_home / ".env", Path("/opt/data/.hermes/.env")):
        val = _read_dotenv_gemini_key(candidate)
        if val:
            return val
    return ""


def resolve_tts_voice(language: str, explicit_voice: Any = None) -> str:
    if isinstance(explicit_voice, str):
        candidate = explicit_voice.strip()
        if candidate:
            canonical = _GEMINI_VOICE_CANONICAL.get(candidate.lower())
            if canonical:
                return canonical
            if _CUSTOM_GEMINI_VOICE_RE.match(candidate):
                return candidate
    return DEFAULT_ES_VOICE if language == "es" else DEFAULT_EN_VOICE


async def _ensure_stt_model(app: web.Application) -> WhisperModel:
    state: dict[str, Any] = app["stt_state"]
    model = state.get("model")
    if model is not None:
        return model
    lock: asyncio.Lock = app["stt_lock"]
    async with lock:
        model = state.get("model")
        if model is not None:
            return model
        logger.info("Loading faster-whisper model %r (device=cpu, compute_type=int8)...", STT_MODEL_NAME)
        model = await asyncio.to_thread(
            WhisperModel,
            STT_MODEL_NAME,
            device="cpu",
            compute_type="int8",
        )
        state["model"] = model
        logger.info("faster-whisper model %r loaded.", STT_MODEL_NAME)
        return model


async def _warmup_stt(app: web.Application) -> None:
    try:
        await _ensure_stt_model(app)
    except Exception:
        logger.exception("Failed to pre-load faster-whisper model during startup")


async def _transcribe_audio_bytes(
    app: web.Application,
    audio_bytes: bytes,
    suffix: str,
    *,
    forced_language: str | None = None,
) -> tuple[str, str | None]:
    model = await _ensure_stt_model(app)

    def _run_transcribe() -> tuple[str, str | None]:
        tmp_path = ""
        try:
            with tempfile.NamedTemporaryFile(prefix="hermes-vb-", suffix=suffix, delete=False) as tmp:
                tmp.write(audio_bytes)
                tmp_path = tmp.name
            kwargs: dict[str, Any] = {
                "beam_size": 5,
                "vad_filter": True,
                "condition_on_previous_text": False,
            }
            if forced_language:
                kwargs["language"] = forced_language
            segments, info = model.transcribe(tmp_path, **kwargs)
            text = " ".join(seg.text.strip() for seg in segments if getattr(seg, "text", "").strip()).strip()
            return text, getattr(info, "language", None)
        finally:
            if tmp_path:
                try:
                    Path(tmp_path).unlink(missing_ok=True)
                except OSError:
                    pass

    return await asyncio.to_thread(_run_transcribe)


class TTSNotConfiguredError(RuntimeError):
    pass


def _rate_to_style_hint(rate: Any) -> str:
    if rate is None or isinstance(rate, bool):
        return ""
    try:
        if isinstance(rate, (int, float)):
            speed = float(rate)
        elif isinstance(rate, str):
            raw = rate.strip()
            if not raw:
                return ""
            if raw.endswith("%"):
                speed = 1.0 + (float(raw[:-1].strip()) / 100.0)
            else:
                speed = float(raw)
        else:
            return ""
    except ValueError:
        return ""
    if not math.isfinite(speed):
        return ""
    if speed >= 1.2:
        return "speaking briskly"
    if speed <= 0.85:
        return "speaking slowly"
    return ""


def _extract_gemini_audio_b64(data: dict[str, Any]) -> str:
    audio_b64 = ""
    for step in data.get("steps") or []:
        if not isinstance(step, dict) or step.get("type") != "model_output":
            continue
        for item in step.get("content") or []:
            if isinstance(item, dict) and item.get("type") == "audio" and item.get("data"):
                audio_b64 = str(item["data"])
    return audio_b64


def _encode_wav_or_mp3(audio_raw: bytes) -> tuple[bytes, str]:
    wav_bytes = (
        audio_raw
        if audio_raw.startswith(b"RIFF")
        else _wrap_pcm16_wav(audio_raw, sample_rate=24000, channels=1, sample_width=2)
    )
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        proc = subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "wav", "-i", "pipe:0", "-f", "mp3", "-b:a", "96k", "pipe:1"],
            input=wav_bytes,
            capture_output=True,
            timeout=30,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout, "audio/mpeg"
        stderr = proc.stderr.decode("utf-8", errors="ignore")[:200]
        logger.warning("ffmpeg wav->mp3 transcode failed (rc=%s): %s; returning WAV", proc.returncode, stderr)
    return wav_bytes, "audio/wav"


async def _synthesize_gemini_tts(
    app: web.Application,
    text: str,
    *,
    voice: str,
    rate: Any = None,
    style: str | None = None,
) -> tuple[bytes, str]:
    api_key = _get_gemini_api_key()
    if not api_key:
        raise TTSNotConfiguredError(
            "GEMINI_API_KEY not configured. Add it in Hermes Webapp "
            "(Settings -> Providers -> API Keys -> Google Gemini) or set GEMINI_API_KEY in Cloud Run Secret Manager."
        )

    spoken = clean_text_for_tts(text)
    if not spoken:
        raise ValueError("No speakable text after cleanup")

    text_block: dict[str, Any] = {"type": "text", "text": spoken}
    resolved_style = (style or "").strip() or _rate_to_style_hint(rate)
    if resolved_style:
        text_block["annotations"] = [{"type": "speech_metadata", "style": resolved_style}]

    payload = {
        "model": GEMINI_TTS_MODEL,
        "input": [{"type": "user_input", "content": [text_block]}],
        "response_format": {"type": "audio"},
        "generation_config": {"speech_config": [{"voice": voice}]},
    }

    session: aiohttp.ClientSession = app["http_client"]
    url = f"{GEMINI_API_BASE}/interactions"
    headers = {"x-goog-api-key": api_key, "Content-Type": "application/json"}

    async with session.post(url, json=payload, headers=headers) as resp:
        raw_body = await resp.text()
        if resp.status >= 400:
            detail = raw_body[:300]
            try:
                err_json = json.loads(raw_body)
                msg = (err_json.get("error") or {}).get("message")
                if isinstance(msg, str) and msg.strip():
                    detail = msg.strip()[:300]
            except Exception:
                pass
            if api_key in detail:
                detail = detail.replace(api_key, "[REDACTED]")
            raise RuntimeError(f"Gemini TTS API error (HTTP {resp.status}): {detail}")
        data = json.loads(raw_body)

    audio_b64 = _extract_gemini_audio_b64(data if isinstance(data, dict) else {})
    if not audio_b64:
        raise RuntimeError("Gemini TTS response contained no audio data")
    try:
        audio_raw = base64.b64decode(audio_b64)
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError(f"Gemini TTS returned invalid base64 audio: {exc}") from exc
    if not audio_raw:
        raise RuntimeError("Gemini TTS returned empty audio data")

    return await asyncio.to_thread(_encode_wav_or_mp3, audio_raw)


async def _parse_json(request: web.Request) -> dict[str, Any]:
    try:
        data = await request.json()
    except Exception as exc:
        raise ValueError(f"Invalid JSON request body: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("JSON body must be an object")
    return data


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response(
        {
            "status": "ok",
            "stt_model": STT_MODEL_NAME,
            "stt_loaded": request.app["stt_state"].get("model") is not None,
            "tts_provider": "gemini",
            "tts_model": GEMINI_TTS_MODEL,
            "tts_configured": bool(_get_gemini_api_key()),
            "default_en_voice": DEFAULT_EN_VOICE,
            "default_es_voice": DEFAULT_ES_VOICE,
        }
    )


async def handle_transcribe(request: web.Request) -> web.Response:
    auth_err = _check_auth(request)
    if auth_err is not None:
        return auth_err
    try:
        payload = await _parse_json(request)
        audio_bytes, suffix = _decode_audio_payload(payload)
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)

    forced_lang = _normalize_explicit_language(payload.get("language"))
    require_wake_word = _is_truthy(payload.get("require_wake_word"), default=False)

    try:
        transcript, whisper_lang = await _transcribe_audio_bytes(
            request.app,
            audio_bytes,
            suffix,
            forced_language=forced_lang,
        )
    except Exception as exc:
        logger.exception("STT transcription error")
        return web.json_response({"error": f"Transcription failed: {exc}"}, status=500)

    lang = detect_language(
        transcript,
        explicit_language=payload.get("language"),
        whisper_language=whisper_lang,
    )
    wake_matched, cleaned = check_wake_word(transcript)
    if require_wake_word and not wake_matched:
        return web.json_response(
            {
                "status": "ignored_no_wake_word",
                "transcript": transcript,
                "language": lang,
                "wake_word_matched": False,
            }
        )

    return web.json_response(
        {
            "status": "ok",
            "transcript": transcript,
            "cleaned_transcript": cleaned,
            "language": lang,
            "wake_word_matched": wake_matched,
        }
    )


async def handle_speak(request: web.Request) -> web.Response:
    auth_err = _check_auth(request)
    if auth_err is not None:
        return auth_err
    try:
        payload = await _parse_json(request)
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)

    text = str(payload.get("text") or "").strip()
    if not text:
        return web.json_response({"error": "text is required"}, status=400)

    lang = detect_language(text, explicit_language=payload.get("language"))
    voice = resolve_tts_voice(lang, payload.get("voice"))
    rate = payload.get("rate")
    raw_style = payload.get("style")
    style = raw_style.strip() if isinstance(raw_style, str) else None

    try:
        audio_bytes, mime_type = await _synthesize_gemini_tts(
            request.app, text, voice=voice, rate=rate, style=style
        )
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)
    except TTSNotConfiguredError as exc:
        return web.json_response({"error": str(exc)}, status=503)
    except Exception as exc:
        logger.exception("Gemini TTS synthesis failed")
        return web.json_response({"error": f"TTS synthesis failed: {exc}"}, status=500)

    if request.query.get("format", "").lower() == "binary":
        return web.Response(body=audio_bytes, content_type=mime_type)

    return web.json_response(
        {
            "status": "ok",
            "voice": voice,
            "language": lang,
            "mime_type": mime_type,
            "audio_base64": base64.b64encode(audio_bytes).decode("ascii"),
        }
    )


async def _call_hermes_chat(
    app: web.Application,
    *,
    prompt: str,
    language: str,
    model: str,
    profile: str | None,
    include_audio: bool,
    user_id: str | None,
) -> str:
    api_key = _get_expected_api_key()
    if not api_key:
        raise RuntimeError("API_SERVER_KEY is not configured")

    if profile:
        if not _PROFILE_RE.match(profile):
            raise ValueError(f"Invalid profile name: {profile!r}")
        url = f"{HERMES_API_BASE}/p/{profile}/v1/chat/completions"
    else:
        url = f"{HERMES_API_BASE}/v1/chat/completions"

    messages: list[dict[str, str]] = []
    if language == "es":
        messages.append(
            {
                "role": "system",
                "content": (
                    "Responde siempre en español (es-US) de forma natural, clara y concisa "
                    "para ser escuchada en voz alta. No uses formato Markdown ni bloques de código "
                    "a menos que se solicite explícitamente."
                ),
            }
        )
    elif include_audio:
        messages.append(
            {
                "role": "system",
                "content": (
                    "Respond naturally and concisely so your reply sounds clear when spoken aloud. "
                    "Avoid markdown formatting or code blocks unless explicitly requested."
                ),
            }
        )
    messages.append({"role": "user", "content": prompt})

    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "stream": False,
    }
    if user_id:
        body["user"] = user_id

    session: aiohttp.ClientSession = app["http_client"]
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    async with session.post(url, json=body, headers=headers) as resp:
        raw_text = await resp.text()
        if resp.status >= 400:
            raise RuntimeError(f"Hermes API error ({resp.status}): {raw_text[:400]}")
        data = await resp.json()

    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("Hermes API returned no choices")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        parts = [str(item.get("text", "")) for item in content if isinstance(item, dict) and item.get("text")]
        return " ".join(parts).strip()
    return str(content or "").strip()


async def handle_voice_chat(request: web.Request) -> web.Response:
    auth_err = _check_auth(request)
    if auth_err is not None:
        return auth_err
    try:
        payload = await _parse_json(request)
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)

    require_wake_word = _is_truthy(payload.get("require_wake_word"), default=False)
    include_audio = _is_truthy(payload.get("include_audio"), default=True)
    model = str(payload.get("model") or DEFAULT_CHAT_MODEL).strip() or DEFAULT_CHAT_MODEL
    profile_raw = payload.get("profile")
    profile = str(profile_raw).strip() if isinstance(profile_raw, str) and profile_raw.strip() else None
    user_raw = payload.get("user") or payload.get("session_id")
    user_id = str(user_raw).strip() if user_raw is not None and str(user_raw).strip() else None

    if payload.get("audio_base64"):
        try:
            audio_bytes, suffix = _decode_audio_payload(payload)
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
        forced_lang = _normalize_explicit_language(payload.get("language"))
        try:
            transcript, whisper_lang = await _transcribe_audio_bytes(
                request.app,
                audio_bytes,
                suffix,
                forced_language=forced_lang,
            )
        except Exception as exc:
            logger.exception("Voice chat STT failure")
            return web.json_response({"error": f"Transcription failed: {exc}"}, status=500)
    else:
        transcript = str(payload.get("text") or payload.get("transcript") or "").strip()
        whisper_lang = None
        if not transcript:
            return web.json_response({"error": "audio_base64 or text/transcript is required"}, status=400)

    lang = detect_language(
        transcript,
        explicit_language=payload.get("language"),
        whisper_language=whisper_lang,
    )
    wake_matched, cleaned_transcript = check_wake_word(transcript)
    if require_wake_word and not wake_matched:
        return web.json_response(
            {
                "status": "ignored_no_wake_word",
                "transcript": transcript,
                "language": lang,
                "wake_word_matched": False,
            }
        )

    if not cleaned_transcript:
        return web.json_response({"error": "Empty transcript"}, status=400)

    try:
        reply = await _call_hermes_chat(
            request.app,
            prompt=cleaned_transcript,
            language=lang,
            model=model,
            profile=profile,
            include_audio=include_audio,
            user_id=user_id,
        )
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)
    except Exception as exc:
        logger.exception("Voice chat completion failure")
        return web.json_response({"error": str(exc)}, status=502)

    if not _normalize_explicit_language(payload.get("language")) and lang != "es":
        if detect_language(reply) == "es":
            lang = "es"
    voice = resolve_tts_voice(lang, payload.get("voice"))
    raw_style = payload.get("style")
    style = raw_style.strip() if isinstance(raw_style, str) else None
    audio_b64 = None
    mime_type = "audio/mpeg"
    if include_audio and reply:
        try:
            audio_bytes, mime_type = await _synthesize_gemini_tts(
                request.app, reply, voice=voice, rate=payload.get("rate"), style=style
            )
            audio_b64 = base64.b64encode(audio_bytes).decode("ascii")
        except TTSNotConfiguredError as exc:
            logger.warning("Voice chat TTS skipped: %s", exc)
        except Exception:
            logger.exception("Voice chat TTS synthesis failed; returning text reply without audio")

    result: dict[str, Any] = {
        "status": "ok",
        "transcript": transcript,
        "cleaned_transcript": cleaned_transcript,
        "reply": reply,
        "language": lang,
        "voice": voice,
        "model": model,
        "mime_type": mime_type,
        "audio_base64": audio_b64,
    }
    return web.json_response(result)


async def on_startup(app: web.Application) -> None:
    timeout = aiohttp.ClientTimeout(total=180, sock_connect=10, sock_read=180)
    app["http_client"] = aiohttp.ClientSession(timeout=timeout)
    app["warmup_task"] = asyncio.create_task(_warmup_stt(app))


async def on_cleanup(app: web.Application) -> None:
    warmup = app.get("warmup_task")
    if warmup is not None and not warmup.done():
        warmup.cancel()
    client: aiohttp.ClientSession | None = app.get("http_client")
    if client is not None:
        await client.close()


def create_app() -> web.Application:
    app = web.Application(client_max_size=64 * 1024 * 1024)
    app["stt_lock"] = asyncio.Lock()
    app["stt_state"] = {"model": None}
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_get("/v1/voice/health", handle_health)
    app.router.add_post("/v1/voice/transcribe", handle_transcribe)
    app.router.add_post("/v1/voice/speak", handle_speak)
    app.router.add_post("/v1/voice/chat", handle_voice_chat)
    return app


def main() -> None:
    web.run_app(create_app(), host=HOST, port=PORT, access_log=None)


if __name__ == "__main__":
    main()
