#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ask() {
  local prompt="$1"
  local default="$2"
  local value
  read -rp "${prompt} [${default}]: " value
  echo "${value:-$default}"
}

ask_password() {
  local prompt="$1"
  local default="$2"
  local value confirm
  while true; do
    read -rsp "${prompt} [${default}]: " value
    echo ""
    value="${value:-$default}"
    read -rsp "Confirm password: " confirm
    echo ""
    confirm="${confirm:-$default}"
    [[ "$value" == "$confirm" ]] && break
    echo "Passwords do not match, try again."
  done
  REPLY="$value"
}

echo ""
echo -e "${BOLD}${CYAN}=== Postgres Pod Setup ===${NC}"
echo ""

BASE_NAME=$(ask "Name" "pg-dev")
NAME="${BASE_NAME}-postgres"
NAMESPACE=$(ask "Namespace" "default")
PG_VERSION=$(ask "Postgres version" "16")
PG_USER=$(ask "Postgres user" "postgres")
ask_password "Postgres password" "postgres"
PG_PASSWORD="$REPLY"
PG_DB=$(ask "Database name" "postgres")
STORAGE_SIZE=$(ask "PVC size" "1Gi")

echo ""

apply_manifests() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NAME}-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${NAME}
spec:
  containers:
    - name: postgres
      image: postgres:${PG_VERSION}
      env:
        - name: POSTGRES_USER
          value: "${PG_USER}"
        - name: POSTGRES_PASSWORD
          value: "${PG_PASSWORD}"
        - name: POSTGRES_DB
          value: "${PG_DB}"
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      ports:
        - containerPort: 5432
      volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${NAME}-pvc
  restartPolicy: Never
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${NAME}
  ports:
    - port: 5432
      targetPort: 5432
EOF
}

wait_for_pod() {
  echo "Waiting for pod '${NAME}' to be ready..."
  kubectl wait pod "${NAME}" \
    --namespace="${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=120s
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "Creating resources in namespace '${NAMESPACE}'..."
apply_manifests

wait_for_pod

DSN="postgres://${PG_USER}:${PG_PASSWORD}@${NAME}.${NAMESPACE}.svc.cluster.local:5432/${PG_DB}?sslmode=disable"

echo ""
echo "PostgreSQL is ready."
echo ""
echo "  DSN: ${DSN}"
echo ""
echo "To delete: kubectl delete pod/${NAME} svc/${NAME} pvc/${NAME}-pvc -n ${NAMESPACE}"
