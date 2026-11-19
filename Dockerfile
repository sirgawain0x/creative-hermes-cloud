FROM nousresearch/hermes-agent:stable

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HERMES_HOME="/opt/data/.hermes" \
    HERMES_WRITE_SAFE_ROOT="/opt/data" \
    HERMES_DOCKER_EXEC_AS_ROOT="1" \
    HERMES_ALLOW_ROOT_GATEWAY="1" \
    HERMES_GATEWAY_LOCK_DIR="/tmp/hermes-locks" \
    HF_HOME="/opt/hermes/hf-cache" \
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/root/.local/bin:${PATH}"

# Bake stt-whisper (local faster-whisper STT) and edge-tts into the sealed venv;
# update PM's recorded extra selection and pre-cache faster-whisper 'base' weights (Google Gemini TTS uses HTTP/JSON).
RUN cd /opt/hermes && \
    /usr/local/bin/python3 -c 'from pathlib import Path; from pm.build_env import _record_selection; from pm.environment import managed_environment, prune_site_pth; from pm.native_build import source_build_environment; source = Path("/opt/hermes"); venv = source / ".venv"; extras = ["all", "messaging", "otlp", "anthropic", "bedrock", "azure-identity", "matrix", "google-chat", "fal", "documents", "edge-tts", "stt-whisper"]; env = managed_environment(venv, python=Path("/usr/local/bin/python3"), cache=source / "uv-cache", env=source_build_environment(source), explicit=True); env.sync(source, extras=extras, no_install_project=True, frozen=True); env.check(source / "uv.lock"); prune_site_pth(venv); _record_selection(source, extras)' && \
    /opt/hermes/.venv/bin/python -m docker.build_agent && \
    mkdir -p /opt/hermes/hf-cache && \
    /opt/hermes/.venv/bin/python -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8')" && \
    chmod -R a+rX /opt/hermes/hf-cache && \
    chmod 0644 /opt/hermes/tools/facts.json && \
    rm -f /opt/hermes/.venv/.lock /opt/hermes/pm-runtime/.lock && \
    find /opt/hermes/uv-cache ! -type l -perm -0002 -exec chmod o-w {} +

WORKDIR /app
COPY grove/package.json grove/grove-cli.mjs /opt/lens-grove/
RUN cd /opt/lens-grove && \
    /usr/local/bin/npm install --omit=dev --no-audit && \
    chmod +x /opt/lens-grove/grove-cli.mjs && \
    ln -sf /opt/lens-grove/grove-cli.mjs /usr/local/bin/grove-upload && \
    /usr/local/bin/grove-upload resolve lens://test

COPY config.yaml /app/default_config.yaml
COPY start_hermes.sh /app/start_hermes.sh
COPY voice_bridge.py /app/voice_bridge.py
COPY adk_peer_call.py /app/adk_peer_call.py
COPY skills /app/skills
COPY profiles /app/profiles
RUN chmod +x /app/start_hermes.sh /app/voice_bridge.py /app/adk_peer_call.py && \
    ln -sf /app/adk_peer_call.py /usr/local/bin/adk-peer-call && \
    /usr/local/bin/adk-peer-call --help >/dev/null && \
    mkdir -p /root/.local/bin && \
    ln -sf /opt/hermes/.venv/bin/hermes /root/.local/bin/hermes

# Cloud Run routes external HTTP traffic to $PORT (default 8080)
ENV PORT=8080
EXPOSE 8080 8000 8001 9120

ENTRYPOINT ["/app/start_hermes.sh"]
