#!/bin/bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Preflight ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT=1
  SUDO=""
  warn "Running as root. sudo will be skipped."
else
  IS_ROOT=0
  SUDO="sudo"
fi

[[ "$(uname -s)" != "Linux" ]] && error "This script is Linux-only."
command -v snap >/dev/null  || error "snap not found. Install it: apt-get install -y snapd"
command -v curl >/dev/null  || error "curl not found. Install it: apt-get install -y curl"

total_cpus="$(nproc)"
total_mem_mb="$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)"
[[ "$total_cpus" -lt 2 ]] && error "Kubernetes requires at least 2 CPU cores. This server has ${total_cpus}."

# ─── Addon selector ───────────────────────────────────────────────────────────
ADDON_NAMES=("metrics-server" "ingress" "registry" "cert-manager" "hostpath-storage")
ADDON_DESCS=(
  "kubectl top + HPA support"
  "nginx Ingress controller for HTTP routing"
  "Local Docker registry inside the cluster"
  "Automatic TLS certificates"
  "Persistent volume support via hostPath"
)
ADDON_DEFAULTS=(0 0 0 0 0)

ask_addons() {
  local -a checked=("${ADDON_DEFAULTS[@]}")
  local count="${#ADDON_NAMES[@]}"

  print_menu() {
    echo ""
    echo "  Select addons to enable (toggle by number, Enter to confirm):"
    echo ""
    for i in "${!ADDON_NAMES[@]}"; do
      local box="[ ]"
      [[ "${checked[$i]}" -eq 1 ]] && box="[x]"
      printf "  %d) %s %-22s  %s\n" $((i+1)) "$box" "${ADDON_NAMES[$i]}" "${ADDON_DESCS[$i]}"
    done
    echo ""
  }

  while true; do
    print_menu
    read -rp "  Toggle [1-${count}] or press Enter to confirm: " input
    [[ -z "$input" ]] && break
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= count )); then
      local idx=$((input - 1))
      checked[$idx]=$(( 1 - checked[$idx] ))
    else
      warn "Enter a number between 1 and ${count}, or press Enter to confirm."
    fi
  done

  SELECTED_ADDONS=()
  for i in "${!ADDON_NAMES[@]}"; do
    [[ "${checked[$i]}" -eq 1 ]] && SELECTED_ADDONS+=("${ADDON_NAMES[$i]}")
  done

  [[ "${#SELECTED_ADDONS[@]}" -eq 0 ]] && info "No addons selected." || info "Addons to enable: ${SELECTED_ADDONS[*]}"
  echo ""
}

# ─── Public access prompt ─────────────────────────────────────────────────────
ENABLE_PUBLIC_ACCESS=0

ask_public_access() {
  echo ""
  read -rp "  Expose services to the public internet via ports 80/443? [y/N]: " input
  [[ "${input,,}" != "y" ]] && return

  local busy_ports=()
  for port in 80 443; do
    ss -tlnH "sport = :$port" | grep -q . && busy_ports+=("$port")
  done

  [[ "${#busy_ports[@]}" -gt 0 ]] && error "Port(s) ${busy_ports[*]} already in use. Free them and re-run the script."

  ENABLE_PUBLIC_ACCESS=1
  info "Ports 80 and 443 are free — public access will be enabled."

  if [[ ! " ${SELECTED_ADDONS[*]} " =~ " ingress " ]]; then
    SELECTED_ADDONS+=("ingress")
    info "ingress addon added automatically (required for public access)."
  fi
  echo ""
}

# ─── Interactive questions ─────────────────────────────────────────────────────
echo ""
echo "  System resources: ${total_cpus} CPU cores, ${total_mem_mb} MB RAM"

ask_addons
ask_public_access

INSTALL_HELM=0
read -rp "  Install Helm? [y/N]: " input_helm
[[ "${input_helm,,}" == "y" ]] && INSTALL_HELM=1
echo ""

# ─── 1. MicroK8s ──────────────────────────────────────────────────────────────
if command -v microk8s &>/dev/null; then
  info "MicroK8s already installed: $(microk8s version 2>/dev/null | head -1)"
else
  info "Installing MicroK8s..."
  $SUDO snap install microk8s --classic
fi

# ─── 2. Group membership ──────────────────────────────────────────────────────
if [[ "$IS_ROOT" -eq 0 ]]; then
  if ! groups "$USER" | grep -q microk8s; then
    info "Adding $USER to microk8s group..."
    $SUDO usermod -aG microk8s "$USER"
    $SUDO chown -R "$USER" ~/.kube 2>/dev/null || true
    warn "Group change requires re-login to take effect. Using 'sg microk8s' for this session."
  fi
  MK="sg microk8s -c microk8s"
else
  MK="microk8s"
fi

# ─── 3. Wait for cluster ──────────────────────────────────────────────────────
info "Waiting for MicroK8s to be ready..."
$MK status --wait-ready

# ─── 4. kubectl alias + kubeconfig ───────────────────────────────────────────
info "Setting snap alias: kubectl → microk8s.kubectl..."
$SUDO snap alias microk8s.kubectl kubectl

info "Exporting kubeconfig..."
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

# ─── 5. Helm ──────────────────────────────────────────────────────────────────
if [[ "$INSTALL_HELM" -eq 1 ]]; then
  if command -v helm &>/dev/null; then
    info "Helm already installed: $(helm version --short)"
  else
    info "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
fi

# ─── 6. Addons ────────────────────────────────────────────────────────────────
# dns is always required
info "Enabling dns addon (required)..."
microk8s enable dns

if [[ "${#SELECTED_ADDONS[@]}" -gt 0 ]]; then
  info "Enabling addons: ${SELECTED_ADDONS[*]}"
  for addon in "${SELECTED_ADDONS[@]}"; do
    microk8s enable "$addon"
  done
fi

# ─── 7. Firewall ──────────────────────────────────────────────────────────────
if [[ "$ENABLE_PUBLIC_ACCESS" -eq 1 ]] && command -v ufw &>/dev/null; then
  info "Opening ports 80 and 443 in ufw..."
  $SUDO ufw allow 80/tcp
  $SUDO ufw allow 443/tcp
fi

# ─── 8. Verify ────────────────────────────────────────────────────────────────
info "Verifying cluster..."
microk8s kubectl cluster-info
microk8s kubectl get nodes -o wide

# ─── 9. Aliases ───────────────────────────────────────────────────────────────
ALIASES_BLOCK='
# microk8s aliases
alias mk="microk8s"
alias kc="microk8s kubectl"
alias kubectl="microk8s kubectl"
alias kgp="microk8s kubectl get pods -A"
alias kgn="microk8s kubectl get nodes"
'

SHELL_RC="$HOME/.bashrc"
[[ "${SHELL:-}" == */zsh ]] && SHELL_RC="$HOME/.zshrc"

if ! grep -q 'microk8s aliases' "$SHELL_RC" 2>/dev/null; then
  info "Adding aliases to $SHELL_RC..."
  echo "$ALIASES_BLOCK" >> "$SHELL_RC"
else
  info "Aliases already present in $SHELL_RC, skipping."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "────────────────────────────────────────────────"
info "MicroK8s is up and running!"
echo ""
echo "  Cluster status:   microk8s status"
echo "  Stop cluster:     microk8s stop"
echo "  Start cluster:    microk8s start"
echo "  Enable addon:     microk8s enable <name>"
if [[ "$ENABLE_PUBLIC_ACCESS" -eq 1 ]]; then
  echo ""
  echo "  Public access:    ports 80 and 443 are open"
  echo "  Next step:        create Ingress resources to route traffic to your pods"
fi
echo ""
if [[ "$IS_ROOT" -eq 0 ]]; then
  warn "Re-login (or run 'newgrp microk8s') to apply group membership."
fi
info "────────────────────────────────────────────────"