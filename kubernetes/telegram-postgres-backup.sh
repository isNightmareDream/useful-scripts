#!/bin/bash
set -euo pipefail

# ─── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  BACKUP_SCRIPT="/usr/local/bin/postgres-telegram-backup"
  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

  echo "Removing cron job..."
  $SUDO sed -i '/postgres-telegram-backup/d' /etc/crontab

  echo "Removing backup script..."
  $SUDO rm -f "$BACKUP_SCRIPT"

  echo "Removing log file..."
  $SUDO rm -f /var/log/postgres-telegram-backup.log

  read -rp "Also delete local backups in /var/backups/postgres? [y/N]: " del_backups
  if [[ "${del_backups,,}" == "y" ]]; then
    $SUDO rm -rf /var/backups/postgres
    echo "Backup directory removed."
  fi

  echo "Uninstall complete."
  exit 0
fi

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Preflight ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

command -v kubectl >/dev/null || error "kubectl not found."
command -v curl    >/dev/null || error "curl not found."
kubectl cluster-info &>/dev/null || error "Cannot connect to Kubernetes cluster."

if ! command -v zstd &>/dev/null; then
  info "Installing zstd..."
  $SUDO apt-get install -y zstd
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
KEEP_DAYS="${KEEP_DAYS:-7}"
CHUNK_SIZE="45m"

# ─── Namespace picker ─────────────────────────────────────────────────────────
echo ""
echo -e "  ${YELLOW}── PostgreSQL connection details ──────────────────${NC}"
echo ""

mapfile -t NAMESPACES < <(kubectl get namespaces --no-headers -o custom-columns=':metadata.name')
[[ "${#NAMESPACES[@]}" -eq 0 ]] && error "No namespaces found."

echo -e "  ${GREEN}Select namespace:${NC}"
echo ""
for i in "${!NAMESPACES[@]}"; do
  printf "    ${YELLOW}%d)${NC} %s\n" $((i+1)) "${NAMESPACES[$i]}"
done
echo ""

while true; do
  read -rp "  Enter number [1-${#NAMESPACES[@]}]: " ns_input
  if [[ "$ns_input" =~ ^[0-9]+$ ]] && (( ns_input >= 1 && ns_input <= ${#NAMESPACES[@]} )); then
    PG_NAMESPACE="${NAMESPACES[$((ns_input-1))]}"
    break
  fi
  warn "Enter a number between 1 and ${#NAMESPACES[@]}."
done
echo -e "  ${GREEN}✔${NC} Namespace: ${YELLOW}${PG_NAMESPACE}${NC}"
echo ""

# ─── Pod picker ───────────────────────────────────────────────────────────────
mapfile -t RAW_PODS < <(kubectl get pods -n "$PG_NAMESPACE" --no-headers 2>/dev/null)
[[ "${#RAW_PODS[@]}" -eq 0 ]] && error "No pods found in namespace '$PG_NAMESPACE'."

echo -e "  ${GREEN}Select pod:${NC}"
echo ""
printf "    %-4s %-40s %-10s %s\n" "No." "NAME" "STATUS" "READY"
printf "    %-4s %-40s %-10s %s\n" "───" "────────────────────────────────────────" "──────────" "─────"
for i in "${!RAW_PODS[@]}"; do
  read -r pod_name pod_ready pod_status _ <<< "${RAW_PODS[$i]}"
  if [[ "$pod_status" == "Running" ]]; then status_color="${GREEN}"; else status_color="${RED}"; fi
  printf "    ${YELLOW}%-4s${NC} %-40s ${status_color}%-10s${NC} %s\n" \
    "$((i+1))" "$pod_name" "$pod_status" "$pod_ready"
done
echo ""

while true; do
  read -rp "  Enter number [1-${#RAW_PODS[@]}]: " pod_input
  if [[ "$pod_input" =~ ^[0-9]+$ ]] && (( pod_input >= 1 && pod_input <= ${#RAW_PODS[@]} )); then
    PG_POD="$(echo "${RAW_PODS[$((pod_input-1))]}" | awk '{print $1}')"
    break
  fi
  warn "Enter a number between 1 and ${#RAW_PODS[@]}."
done
echo -e "  ${GREEN}✔${NC} Pod: ${YELLOW}${PG_POD}${NC}"
echo ""

# ─── Read env vars from pod ───────────────────────────────────────────────────
info "Reading environment variables from pod '$PG_POD'..."

PG_CONTAINER="$(kubectl get pod "$PG_POD" -n "$PG_NAMESPACE" \
  -o jsonpath='{.spec.containers[0].name}')"

get_env() {
  kubectl exec -n "$PG_NAMESPACE" "$PG_POD" -c "$PG_CONTAINER" \
    -- printenv "$1" 2>/dev/null || true
}

ENV_DB="$(get_env POSTGRES_DB)"
ENV_USER="$(get_env POSTGRES_USER)"

if [[ -n "$ENV_DB" || -n "$ENV_USER" ]]; then
  echo ""
  echo -e "  ${GREEN}Found in pod environment:${NC}"
  [[ -n "$ENV_DB"   ]] && echo -e "    POSTGRES_DB:   ${YELLOW}${ENV_DB}${NC}"
  [[ -n "$ENV_USER" ]] && echo -e "    POSTGRES_USER: ${YELLOW}${ENV_USER}${NC}"
  echo ""
  read -rp "  Use these values? [Y/n]: " use_env
  if [[ "${use_env,,}" != "n" ]]; then
    PG_DATABASE="${ENV_DB:-postgres}"
    PG_USER="${ENV_USER:-postgres}"
    echo -e "  ${GREEN}✔${NC} Using values from pod."
    echo ""
  else
    read -rp "  Postgres database name: " PG_DATABASE
    [[ -z "$PG_DATABASE" ]] && error "Database name is required."
    read -rp "  Postgres user [default: postgres]: " PG_USER
    PG_USER="${PG_USER:-postgres}"
    echo ""
  fi
else
  warn "Could not read env vars from pod. Enter manually."
  echo ""
  read -rp "  Postgres database name: " PG_DATABASE
  [[ -z "$PG_DATABASE" ]] && error "Database name is required."
  read -rp "  Postgres user [default: postgres]: " PG_USER
  PG_USER="${PG_USER:-postgres}"
  echo ""
fi

# ─── Telegram credentials ─────────────────────────────────────────────────────
echo -e "  ${YELLOW}── Telegram settings ──────────────────────────────${NC}"
echo ""
echo "  To get a bot token: message @BotFather → /newbot"
echo "  To get your chat_id: message your bot → open"
echo "  https://api.telegram.org/bot<TOKEN>/getUpdates"
echo ""

read -rp "  Bot token: " TG_TOKEN
[[ -z "$TG_TOKEN" ]] && error "Bot token is required."

read -rp "  Your chat_id: " TG_CHAT_ID
[[ -z "$TG_CHAT_ID" ]] && error "Chat ID is required."

echo ""
info "Verifying Telegram bot..."
tg_check=$(curl -sf "https://api.telegram.org/bot${TG_TOKEN}/getMe" | grep -o '"ok":true' || true)
[[ "$tg_check" != '"ok":true' ]] && error "Invalid bot token or Telegram unreachable."
info "Bot token is valid."
echo ""

read -rp "  Keep local backups for how many days? [default: ${KEEP_DAYS}]: " input_keep
KEEP_DAYS="${input_keep:-$KEEP_DAYS}"

# ─── Create backup directory ──────────────────────────────────────────────────
info "Creating backup directory $BACKUP_DIR..."
$SUDO mkdir -p "$BACKUP_DIR"
$SUDO chmod 750 "$BACKUP_DIR"

# ─── Write backup script ──────────────────────────────────────────────────────
BACKUP_SCRIPT="/usr/local/bin/postgres-telegram-backup"
info "Writing backup script to $BACKUP_SCRIPT..."

$SUDO tee "$BACKUP_SCRIPT" >/dev/null <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

SCRIPT_EOF

$SUDO tee -a "$BACKUP_SCRIPT" >/dev/null <<EOF
PG_NAMESPACE="${PG_NAMESPACE}"
PG_POD="${PG_POD}"
PG_CONTAINER="${PG_CONTAINER}"
PG_USER="${PG_USER}"
PG_DATABASE="${PG_DATABASE}"
TG_TOKEN="${TG_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
BACKUP_DIR="${BACKUP_DIR}"
KEEP_DAYS="${KEEP_DAYS}"
CHUNK_SIZE="${CHUNK_SIZE}"
EOF

$SUDO tee -a "$BACKUP_SCRIPT" >/dev/null <<'SCRIPT_EOF'

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
TIMESTAMP_READABLE="$(date '+%Y-%m-%d %H:%M:%S')"
BACKUP_FILE="${BACKUP_DIR}/${PG_DATABASE}_${TIMESTAMP}.sql.zst"
TG_API="https://api.telegram.org/bot${TG_TOKEN}"

tg_send_message() {
  curl -sf "${TG_API}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d text="$1" \
    -d parse_mode="Markdown" >/dev/null
}

tg_send_file() {
  local file="$1"
  local caption="$2"
  curl -sf "${TG_API}/sendDocument" \
    -F chat_id="${TG_CHAT_ID}" \
    -F document=@"${file}" \
    -F caption="${caption}" >/dev/null
}

echo "[$(date)] Starting backup of '${PG_DATABASE}'..."

kubectl exec -n "${PG_NAMESPACE}" "${PG_POD}" -c "${PG_CONTAINER}" -- \
  pg_dump -U "${PG_USER}" "${PG_DATABASE}" | zstd -19 -o "${BACKUP_FILE}"

BACKUP_SIZE="$(du -sh "${BACKUP_FILE}" | cut -f1)"
echo "[$(date)] Backup saved: ${BACKUP_FILE} (${BACKUP_SIZE})"

# Split into chunks and send
CHUNK_DIR="${BACKUP_DIR}/.chunks_${TIMESTAMP}"
mkdir -p "${CHUNK_DIR}"
split -b "${CHUNK_SIZE}" "${BACKUP_FILE}" "${CHUNK_DIR}/${PG_DATABASE}_${TIMESTAMP}.part."

CHUNKS=("${CHUNK_DIR}"/*)
TOTAL="${#CHUNKS[@]}"

if [[ "$TOTAL" -eq 1 ]]; then
  echo "[$(date)] Sending backup to Telegram..."
  tg_send_file "${BACKUP_FILE}" "✅ ${PG_DATABASE} | ${TIMESTAMP_READABLE} | ${BACKUP_SIZE}"
else
  echo "[$(date)] Backup is large (${BACKUP_SIZE}), sending ${TOTAL} parts..."
  for i in "${!CHUNKS[@]}"; do
    part_num=$((i+1))
    echo "[$(date)] Sending part ${part_num}/${TOTAL}..."
    tg_send_file "${CHUNKS[$i]}" "📦 ${PG_DATABASE} | ${TIMESTAMP_READABLE} | part ${part_num}/${TOTAL}"
  done
fi

rm -rf "${CHUNK_DIR}"

# Remove old backups
find "${BACKUP_DIR}" -name "${PG_DATABASE}_*.sql.zst" -mtime "+${KEEP_DAYS}" -delete
echo "[$(date)] Done."
SCRIPT_EOF

$SUDO chmod +x "$BACKUP_SCRIPT"

# ─── Setup cron ───────────────────────────────────────────────────────────────
info "Setting up daily cron job (runs at 03:00)..."
CRON_LINE="0 3 * * * root $BACKUP_SCRIPT >> /var/log/postgres-telegram-backup.log 2>&1"

if $SUDO grep -q "postgres-telegram-backup" /etc/crontab 2>/dev/null; then
  warn "Cron job already exists in /etc/crontab, skipping."
else
  echo "$CRON_LINE" | $SUDO tee -a /etc/crontab >/dev/null
  info "Cron job added."
fi

# ─── Test backup ──────────────────────────────────────────────────────────────
echo ""
read -rp "  Run a test backup now? [Y/n]: " input_test
if [[ "${input_test,,}" != "n" ]]; then
  info "Running test backup..."
  bash "$BACKUP_SCRIPT"
  info "Test backup done."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "────────────────────────────────────────────────"
info "Telegram backup configured!"
echo ""
echo "  Backup script:    $BACKUP_SCRIPT"
echo "  Backup directory: $BACKUP_DIR"
echo "  Schedule:         daily at 03:00"
echo "  Retention:        ${KEEP_DAYS} days"
echo "  Logs:             tail -f /var/log/postgres-telegram-backup.log"
echo ""
echo "  Run manually:     $BACKUP_SCRIPT"
info "────────────────────────────────────────────────"
