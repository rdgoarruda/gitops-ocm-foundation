#!/bin/bash
# fix-ips.sh - Atualiza IPs após reinício do ambiente Kind (6 clusters)
#
# Após um reboot, os containers Kind podem receber novos IPs na rede Docker.
# Este script detecta os IPs atuais e atualiza:
#   - /etc/hosts (argocd-ho.local / argocd-pr.local)
#   - CoreDNS ConfigMaps nos clusters worker (bu-a-ho, bu-a-pr, bu-b-ho, bu-b-pr)
#   - ArgoCD cluster Secrets nos hubs (gerencia-ho, gerencia-pr)
#   - Hub kubeconfig Secrets nos add-ons de governance dos clusters worker
#   - Limites de inotify nos nodes kind
#   - Reinicia os componentes afetados
#
# Uso: ./scripts/fix-ips.sh [--only ho|pr]

set -euo pipefail
export PATH="$PATH:$(cd "$(dirname "$0")/.." && pwd)/bin"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Parse args ─────────────────────────────────────────────────────────────
SCOPE="${1:-all}"
case "$SCOPE" in
  --only) SCOPE="${2:-all}" ;;
esac

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
abort() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── 1. Detectar IPs atuais ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "   fix-ips.sh — Restaurando ambiente Kind após reboot  "
echo "════════════════════════════════════════════════════════"
echo ""

get_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null \
    || abort "Container '$1' não encontrado. docker ps para conferir."
}

# Detectar IPs
declare -A CLUSTER_IPS
ALL_CLUSTERS=()

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  ALL_CLUSTERS+=(gerencia-ho bu-a-ho bu-b-ho)
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  ALL_CLUSTERS+=(gerencia-pr bu-a-pr bu-b-pr)
fi

for cluster in "${ALL_CLUSTERS[@]}"; do
  CLUSTER_IPS[$cluster]=$(get_ip "${cluster}-control-plane")
done

info "IPs detectados:"
for cluster in "${ALL_CLUSTERS[@]}"; do
  printf "     %-15s → %s\n" "$cluster" "${CLUSTER_IPS[$cluster]}"
done
echo ""

# ── 2. Aumentar limites de inotify nos nodes ────────────────────────────────
info "Ajustando limites de inotify em todos os nodes..."
for cluster in "${ALL_CLUSTERS[@]}"; do
  container="${cluster}-control-plane"
  docker exec "$container" sh -c \
    'grep -q "max_user_watches=524288" /etc/sysctl.conf || echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
     grep -q "max_user_instances=512" /etc/sysctl.conf  || echo "fs.inotify.max_user_instances=512"  >> /etc/sysctl.conf
     sysctl -p > /dev/null 2>&1' \
    && echo "     $container → ok"
done
echo ""

# ── 3. Atualizar /etc/hosts ─────────────────────────────────────────────────
info "Atualizando /etc/hosts..."
update_hosts() {
  local hostname="$1"
  local new_ip="$2"
  if grep -q "$hostname" /etc/hosts 2>/dev/null; then
    current_ip=$(grep "$hostname" /etc/hosts | awk '{print $1}')
    if [ "$current_ip" != "$new_ip" ]; then
      warn "  $hostname: $current_ip → $new_ip  (requer sudo)"
      sudo sed -i "s|^.*$hostname|$new_ip $hostname|" /etc/hosts
    else
      echo "     $hostname → $new_ip (sem mudança)"
    fi
  else
    warn "  $hostname não encontrado em /etc/hosts — adicionando (requer sudo)"
    echo "$new_ip $hostname" | sudo tee -a /etc/hosts > /dev/null
  fi
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  update_hosts "argocd-ho.local" "${CLUSTER_IPS[gerencia-ho]}"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  update_hosts "argocd-pr.local" "${CLUSTER_IPS[gerencia-pr]}"
fi
echo ""

# ── 4. Atualizar CoreDNS nos clusters worker ────────────────────────────────
info "Atualizando ConfigMap CoreDNS..."

update_coredns() {
  local ctx="$1"
  local hub_ip="$2"
  local hub_hostname="$3"
  local cm_file="$4"

  # Substitui qualquer IP no campo do hub pelo IP atual
  sed -i "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ ${hub_hostname}|${hub_ip} ${hub_hostname}|g" "$cm_file"
  kubectl --context "$ctx" apply -f "$cm_file"
  kubectl --context "$ctx" rollout restart deploy/coredns -n kube-system
  echo "     $ctx → $hub_ip (coredns reiniciado)"
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  HUB_HO_IP="${CLUSTER_IPS[gerencia-ho]}"
  update_coredns "kind-bu-a-ho" "$HUB_HO_IP" "gerencia-ho-control-plane" \
    "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-bu-a-ho.yaml"
  update_coredns "kind-bu-b-ho" "$HUB_HO_IP" "gerencia-ho-control-plane" \
    "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-bu-b-ho.yaml"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  HUB_PR_IP="${CLUSTER_IPS[gerencia-pr]}"
  update_coredns "kind-bu-a-pr" "$HUB_PR_IP" "gerencia-pr-control-plane" \
    "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-bu-a-pr.yaml"
  update_coredns "kind-bu-b-pr" "$HUB_PR_IP" "gerencia-pr-control-plane" \
    "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-bu-b-pr.yaml"
fi
echo ""

# ── 5. Atualizar ArgoCD cluster Secrets ────────────────────────────────────
info "Atualizando ArgoCD cluster Secrets..."

patch_argocd_secret() {
  local hub_ctx="$1"
  local secret_name="$2"
  local cluster_ip="$3"
  local current_server
  current_server=$(kubectl --context "$hub_ctx" get secret "$secret_name" \
    -n argocd -o jsonpath='{.data.server}' | base64 -d 2>/dev/null || echo "")
  local new_server="https://${cluster_ip}:6443"
  if [ "$current_server" != "$new_server" ]; then
    kubectl --context "$hub_ctx" patch secret "$secret_name" \
      -n argocd -p "{\"stringData\":{\"server\":\"$new_server\"}}"
    echo "     $secret_name → $new_server"
  else
    echo "     $secret_name → $new_server (sem mudança)"
  fi
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  patch_argocd_secret "kind-gerencia-ho" "cluster-bu-a-ho" "${CLUSTER_IPS[bu-a-ho]}"
  patch_argocd_secret "kind-gerencia-ho" "cluster-bu-b-ho" "${CLUSTER_IPS[bu-b-ho]}"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  patch_argocd_secret "kind-gerencia-pr" "cluster-bu-a-pr" "${CLUSTER_IPS[bu-a-pr]}"
  patch_argocd_secret "kind-gerencia-pr" "cluster-bu-b-pr" "${CLUSTER_IPS[bu-b-pr]}"
fi
echo ""

# ── 6. Atualizar hub kubeconfig Secrets nos add-ons de governance ───────────
info "Atualizando hub kubeconfig nos add-ons de governance..."

patch_hub_kubeconfig() {
  local ctx="$1"
  local ns="$2"
  local secret="$3"
  local hub_ip="$4"
  local exists
  exists=$(kubectl --context "$ctx" get secret "$secret" -n "$ns" \
    --no-headers --ignore-not-found 2>/dev/null | wc -l)
  [ "$exists" -eq 0 ] && { echo "     $ctx/$secret → não existe, pulando"; return; }

  local has_kubeconfig
  has_kubeconfig=$(kubectl --context "$ctx" get secret "$secret" -n "$ns" \
    -o jsonpath='{.data.kubeconfig}' 2>/dev/null || echo "")
  [ -z "$has_kubeconfig" ] && { echo "     $ctx/$secret → campo kubeconfig ausente, pulando"; return; }

  local new_kc
  new_kc=$(kubectl --context "$ctx" get secret "$secret" -n "$ns" \
    -o jsonpath='{.data.kubeconfig}' | base64 -d \
    | sed "s|https://[0-9.]*:6443|https://$hub_ip:6443|g" \
    | base64 -w 0)
  kubectl --context "$ctx" patch secret "$secret" -n "$ns" \
    -p "{\"data\":{\"kubeconfig\":\"$new_kc\"}}"
  echo "     $ctx → $secret atualizado (hub → $hub_ip)"
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  HUB_HO_IP="${CLUSTER_IPS[gerencia-ho]}"
  # Workers
  for ctx in kind-bu-a-ho kind-bu-b-ho; do
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
      "governance-policy-framework-hub-kubeconfig" "$HUB_HO_IP"
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
      "config-policy-controller-hub-kubeconfig" "$HUB_HO_IP"
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent" \
      "hub-kubeconfig-secret" "$HUB_HO_IP"
  done
  # Hub auto-registrado como in-cluster
  patch_hub_kubeconfig "kind-gerencia-ho" "open-cluster-management-agent-addon" \
    "governance-policy-framework-hub-kubeconfig" "$HUB_HO_IP"
  patch_hub_kubeconfig "kind-gerencia-ho" "open-cluster-management-agent-addon" \
    "config-policy-controller-hub-kubeconfig" "$HUB_HO_IP"
  patch_hub_kubeconfig "kind-gerencia-ho" "open-cluster-management-agent" \
    "hub-kubeconfig-secret" "$HUB_HO_IP"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  HUB_PR_IP="${CLUSTER_IPS[gerencia-pr]}"
  # Workers
  for ctx in kind-bu-a-pr kind-bu-b-pr; do
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
      "governance-policy-framework-hub-kubeconfig" "$HUB_PR_IP"
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
      "config-policy-controller-hub-kubeconfig" "$HUB_PR_IP"
    patch_hub_kubeconfig "$ctx" "open-cluster-management-agent" \
      "hub-kubeconfig-secret" "$HUB_PR_IP"
  done
  # Hub auto-registrado como in-cluster
  patch_hub_kubeconfig "kind-gerencia-pr" "open-cluster-management-agent-addon" \
    "governance-policy-framework-hub-kubeconfig" "$HUB_PR_IP"
  patch_hub_kubeconfig "kind-gerencia-pr" "open-cluster-management-agent-addon" \
    "config-policy-controller-hub-kubeconfig" "$HUB_PR_IP"
  patch_hub_kubeconfig "kind-gerencia-pr" "open-cluster-management-agent" \
    "hub-kubeconfig-secret" "$HUB_PR_IP"
fi
echo ""

# ── 7. Reiniciar componentes afetados ──────────────────────────────────────
info "Reiniciando componentes nos clusters worker..."

restart_worker() {
  local ctx="$1"
  echo "   → $ctx"
  kubectl --context "$ctx" rollout restart ds/kube-proxy -n kube-system 2>/dev/null || true
  kubectl --context "$ctx" rollout restart deploy/local-path-provisioner \
    -n local-path-storage 2>/dev/null || true
  kubectl --context "$ctx" rollout restart deploy/klusterlet \
    -n open-cluster-management-agent 2>/dev/null || true
  kubectl --context "$ctx" rollout restart deploy/klusterlet-agent \
    -n open-cluster-management-agent 2>/dev/null || true
  kubectl --context "$ctx" rollout restart \
    deploy/governance-policy-framework deploy/config-policy-controller \
    -n open-cluster-management-agent-addon 2>/dev/null || true
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  restart_worker "kind-bu-a-ho"
  restart_worker "kind-bu-b-ho"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  restart_worker "kind-bu-a-pr"
  restart_worker "kind-bu-b-pr"
fi
echo ""

restart_hub() {
  local ctx="$1"
  info "Reiniciando componentes em $ctx..."
  kubectl --context "$ctx" rollout restart ds/kube-proxy -n kube-system 2>/dev/null || true
  kubectl --context "$ctx" rollout restart deploy/local-path-provisioner \
    -n local-path-storage 2>/dev/null || true
  kubectl --context "$ctx" rollout restart deploy/klusterlet \
    -n open-cluster-management-agent 2>/dev/null || true
  kubectl --context "$ctx" rollout restart \
    deploy/cluster-manager-addon-manager-controller \
    deploy/cluster-manager-registration-controller \
    -n open-cluster-management-hub 2>/dev/null || true
  kubectl --context "$ctx" rollout restart \
    deploy/governance-policy-propagator \
    -n open-cluster-management 2>/dev/null || true
  # Reiniciar governance addons do hub (in-cluster)
  kubectl --context "$ctx" rollout restart \
    deploy/governance-policy-framework deploy/config-policy-controller \
    -n open-cluster-management-agent-addon 2>/dev/null || true
  # Reiniciar argocd-repo-server (trava frequentemente após reboot)
  kubectl --context "$ctx" delete pod -n argocd \
    -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null || true
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  restart_hub "kind-gerencia-ho"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  restart_hub "kind-gerencia-pr"
fi
echo ""

# ── 8. Aguardar e verificar status final ───────────────────────────────────
info "Aguardando 30s para os pods subirem..."
sleep 30

echo ""
echo "════════════════════ STATUS FINAL ════════════════════"
ALL_OK=true
for cluster in "${ALL_CLUSTERS[@]}"; do
  ctx="kind-${cluster}"
  NOT_READY=$(kubectl --context "$ctx" get pods -A \
    --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
  if [ "$NOT_READY" -gt 0 ]; then
    warn "$ctx → $NOT_READY pod(s) ainda não Running:"
    kubectl --context "$ctx" get pods -A --no-headers | grep -v "Running\|Completed"
    ALL_OK=false
  else
    info "$ctx → todos os pods Running ✅"
  fi
done

echo ""
echo "────────────────────── OCM ───────────────────────────"
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  echo "── gerencia-ho:"
  kubectl --context kind-gerencia-ho get managedclusters 2>/dev/null || warn "OCM Hub não instalado em gerencia-ho"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  echo "── gerencia-pr:"
  kubectl --context kind-gerencia-pr get managedclusters 2>/dev/null || warn "OCM Hub não instalado em gerencia-pr"
fi

echo ""
echo "─────────────────── ArgoCD ───────────────────────────"
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  curl -s -o /dev/null -w "argocd-ho.local HTTP status: %{http_code}\n" http://argocd-ho.local 2>/dev/null \
    || warn "argocd-ho.local inacessível via curl"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  curl -s -o /dev/null -w "argocd-pr.local:8080 HTTP status: %{http_code}\n" http://argocd-pr.local:8080 2>/dev/null \
    || warn "argocd-pr.local:8080 inacessível via curl"
fi
echo ""

if $ALL_OK; then
  info "Ambiente completamente restaurado! 🎉"
else
  warn "Alguns pods ainda não estão Running. Verifique os logs acima."
fi
