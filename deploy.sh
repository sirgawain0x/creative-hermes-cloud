#!/usr/bin/env bash
set -euo pipefail

# === Configuration (override via environment variables if desired) ===
PROJECT_ID="${PROJECT_ID:-creative-ai-491118}"
REGION="${REGION:-us-east1}"
SERVICE_NAME="${SERVICE_NAME:-hermes-swarm}"
BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-hermes-data}"
SA_NAME="${SA_NAME:-hermes-swarm-sa}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Resolve local credentials without hardcoding any secret values in git
resolve_dotenv_value() {
  local key="$1"
  local file="$2"
  if [ -f "${file}" ]; then
    python3 - "${key}" "${file}" <<'PY'
import sys
key, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == key:
            print(v.strip().strip('"').strip("'"))
            break
PY
  fi
}

resolve_dashboard_password() {
  local cfg="${HOME}/.hermes/config.yaml"
  if [ -f "${cfg}" ]; then
    python3 - "${cfg}" <<'PY'
import sys
section = []
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for raw in fh:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        key, val = stripped.split(":", 1)
        key = key.strip()
        val = val.strip()
        while section and section[-1][0] >= indent:
            section.pop()
        section.append((indent, key))
        path = [k for _, k in section]
        if path == ["dashboard", "basic_auth", "password"] and val:
            if (val[0] == val[-1]) and val[0] in ('"', "'"):
                val = val[1:-1]
            if val:
                print(val)
            break
PY
  fi
}

OLLAMA_API_KEY_VAL="${OLLAMA_API_KEY:-$(resolve_dotenv_value OLLAMA_API_KEY "${HOME}/.hermes/.env")}"
HERMES_API_KEY_VAL="${HERMES_API_KEY:-${API_SERVER_KEY:-$(resolve_dotenv_value API_SERVER_KEY "${HOME}/.hermes/.env")}}"
HERMES_DASHBOARD_PASSWORD_VAL="${HERMES_DASHBOARD_PASSWORD:-$(resolve_dashboard_password)}"

if [ -z "${OLLAMA_API_KEY_VAL}" ]; then
  echo "ERROR: OLLAMA_API_KEY not found in environment or ~/.hermes/.env." >&2
  exit 1
fi
if [ -z "${HERMES_API_KEY_VAL}" ]; then
  HERMES_API_KEY_VAL="$(openssl rand -hex 32)"
fi
if [ -z "${HERMES_DASHBOARD_PASSWORD_VAL}" ]; then
  HERMES_DASHBOARD_PASSWORD_VAL="$(openssl rand -hex 24)"
fi

gcloud config set project "${PROJECT_ID}"

# 1. Enable required Google Cloud APIs
gcloud services enable \
  run.googleapis.com \
  aiplatform.googleapis.com \
  storage.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com

# 2. Create persistent GCS bucket for ~/.hermes memory, skills & SQLite DB
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

# 3. Create Service Account & grant Vertex AI + Storage + Secrets access
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Hermes Swarm Cloud Run SA"
fi

# Wait for IAM propagation of newly created service account before policy bindings
retry_cmd() {
  local attempt=1
  local max_attempts=6
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      return 1
    fi
    echo "Waiting for IAM propagation (attempt ${attempt}/${max_attempts})..." >&2
    sleep 5
    attempt=$((attempt + 1))
  done
}

retry_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --quiet

retry_cmd gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  --quiet

# 4. Create or update secrets in Google Cloud Secret Manager
upsert_secret() {
  local secret_name="$1"
  local secret_value="$2"
  if gcloud secrets describe "${secret_name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    printf '%s' "${secret_value}" | gcloud secrets versions add "${secret_name}" \
      --project="${PROJECT_ID}" \
      --data-file=- >/dev/null
  else
    printf '%s' "${secret_value}" | gcloud secrets create "${secret_name}" \
      --project="${PROJECT_ID}" \
      --replication-policy="automatic" \
      --data-file=- >/dev/null
  fi
  retry_cmd gcloud secrets add-iam-policy-binding "${secret_name}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet >/dev/null
}

upsert_secret "OLLAMA_API_KEY" "${OLLAMA_API_KEY_VAL}"
upsert_secret "HERMES_DASHBOARD_PASSWORD" "${HERMES_DASHBOARD_PASSWORD_VAL}"
upsert_secret "HERMES_API_KEY" "${HERMES_API_KEY_VAL}"

# 5. Build and Deploy to Cloud Run (min-instances=1 keeps gateway & cron alive)
gcloud run deploy "${SERVICE_NAME}" \
  --source . \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --service-account "${SA_EMAIL}" \
  --allow-unauthenticated \
  --execution-environment gen2 \
  --port 8080 \
  --cpu 2 \
  --memory 4Gi \
  --min-instances 1 \
  --max-instances 1 \
  --no-cpu-throttling \
  --timeout 3600 \
  --set-env-vars "GCP_PROJECT_ID=${PROJECT_ID},HERMES_DASHBOARD_USER=admin" \
  --set-secrets "OLLAMA_API_KEY=OLLAMA_API_KEY:latest,HERMES_DASHBOARD_PASSWORD=HERMES_DASHBOARD_PASSWORD:latest,HERMES_API_KEY=HERMES_API_KEY:latest" \
  --add-volume "name=hermes-storage,type=cloud-storage,bucket=${BUCKET_NAME}" \
  --add-volume-mount "volume=hermes-storage,mount-path=/opt/data"

# Clean up superseded zero-traffic revisions so retired containers cannot write to GCS
ACTIVE_REV="$(gcloud run services describe "${SERVICE_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.latestReadyRevisionName)')"
for REV in $(gcloud run revisions list --service="${SERVICE_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(metadata.name)'); do
  if [ "${REV}" != "${ACTIVE_REV}" ]; then
    gcloud run revisions delete "${REV}" --project="${PROJECT_ID}" --region="${REGION}" --quiet >/dev/null 2>&1 || true
  fi
done

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"
echo ""
echo "Deployment complete!"
echo "  - Cloud Run URL: ${SERVICE_URL}"
echo "  - Web Dashboard: ${SERVICE_URL}/"
echo "  - OpenAI-Compatible API: ${SERVICE_URL}/v1/chat/completions"
