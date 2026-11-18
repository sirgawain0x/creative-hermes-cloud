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
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/root/.local/bin:${PATH}"

WORKDIR /app
COPY config.yaml /app/default_config.yaml
COPY start_hermes.sh /app/start_hermes.sh
RUN chmod +x /app/start_hermes.sh && \
    mkdir -p /root/.local/bin && \
    ln -sf /opt/hermes/.venv/bin/hermes /root/.local/bin/hermes

# Cloud Run routes external HTTP traffic to $PORT (default 8080)
ENV PORT=8080
EXPOSE 8080 8000 9119

ENTRYPOINT ["/app/start_hermes.sh"]
