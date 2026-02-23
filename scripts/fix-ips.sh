#!/bin/bash
# fix-ips.sh - Atualiza IPs após reinício do ambiente Kind
#
# Após um reboot, os containers Kind podem receber novos IPs na rede Docker.
# Este script detecta os IPs atuais e atualiza:
#   - /etc/hosts (argocd.local / headlamp.local)
#   - CoreDNS ConfigMaps nos clusters managed (nprod-bu-x, prod-bu-x)
#   - ArgoCD cluster Secrets no gerencia-global
#   - Hub kubeconfig Secrets nos add-ons de governance dos clusters managed
#   - Limites de inotify nos nodes kind (fs.inotify.max_user_watches/instances)
#   - Reinicia os componentes afetados
#
# Uso: ./scripts/fix-ips.sh

set -euo pipefail
export PATH="$PATH:$(cd "$(dirname "$0")/.." && pwd)/bin"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
abort() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── 1. Detectar IPs atuais ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "   fix-ips.sh — Restaurando ambiente Kind após reboot   "
echo "════════════════════════════════════════════════════════"
echo ""

get_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null \
    || abort "Container '$1' não encontrado. docker ps para conferir."
}

HUB_IP=$(get_ip "gerencia-global-control-plane")
NPROD_IP=$(get_ip "nprod-bu-x-control-plane")
PROD_IP=$(get_ip "prod-bu-x-control-plane")

info "IPs detectados:"
echo "     gerencia-global  → $HUB_IP"
echo "     nprod-bu-x       → $NPROD_IP"
echo "     prod-bu-x        → $PROD_IP"
echo ""

# ── 2. Aumentar limites de inotify nos nodes ────────────────────────────────
info "Ajustando limites de inotify em todos os nodes..."
for container in gerencia-global-control-plane nprod-bu-x-control-plane prod-bu-x-control-plane; do
  docker exec "$container" sh -c \
    'grep -q "max_user_watches=524288" /etc/sysctl.conf || echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
     grep -q "max_user_instances=512" /etc/sysctl.conf  || echo "fs.inotify.max_user_instances=512"  >> /etc/sysctl.conf
     sysctl -p > /dev/null 2>&1' \
    && echo "     $container → ok"
done
echo ""

# ── 3. Atualizar /etc/hosts ─────────────────────────────────────────────────
info "Atualizando /etc/hosts..."
HOSTS_FILE="/etc/hosts"
update_hosts() {
  local hostname="$1"
  local new_ip="$2"
  if grep -q "$hostname" "$HOSTS_FILE" 2>/dev/null; then
    # Verifica se precisa mudar
    current_ip=$(grep "$hostname" "$HOSTS_FILE" | awk '{print $1}')
    if [ "$current_ip" != "$new_ip" ]; then
      warn "  $hostname: $current_ip → $new_ip  (requer sudo)"
      sudo sed -i "s|^.*$hostname|$new_ip $hostname|" "$HOSTS_FILE"
    else
      echo "     $hostname → $new_ip (sem mudança)"
    fi
  else
    warn "  $hostname não encontrado em /etc/hosts — adicionando (requer sudo)"
    echo "$new_ip $hostname" | sudo tee -a "$HOSTS_FILE" > /dev/null
  fi
}
update_hosts "argocd.local"   "$HUB_IP"
update_hosts "headlamp.local" "$HUB_IP"
echo ""

# ── 4. Atualizar CoreDNS nos clusters managed ───────────────────────────────
info "Atualizando ConfigMap CoreDNS..."
update_coredns() {
  local ctx="$1"
  local ip="$2"
  local cm_file="$3"

  # Substitui qualquer IP no campo do hub pelo IP atual
  sed -i "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ gerencia-global-control-plane|$HUB_IP gerencia-global-control-plane|g" "$cm_file"
  kubectl --context "$ctx" apply -f "$cm_file" --dry-run=client -o name > /dev/null
  kubectl --context "$ctx" apply -f "$cm_file"
  kubectl --context "$ctx" rollout restart deploy/coredns -n kube-system
  echo "     $ctx → $HUB_IP (coredns reiniciado)"
}
update_coredns "kind-nprod-bu-x" "$NPROD_IP" \
  "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-nprod-bu-x.yaml"
update_coredns "kind-prod-bu-x"  "$PROD_IP"  \
  "$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-prod-bu-x.yaml"
echo ""

# ── 5. Atualizar ApplicationSets no gitops-global ──────────────────────────
GITOPS_GLOBAL="$(cd "$REPO_ROOT/../gitops-global" 2>/dev/null && pwd || echo "")"
if [ -n "$GITOPS_GLOBAL" ] && [ -d "$GITOPS_GLOBAL/domains" ]; then
  info "Atualizando ApplicationSets em gitops-global..."
  # Atualiza todos os appset-tools-nprod.yaml (destinam ao nprod-bu-x)
  find "$GITOPS_GLOBAL/domains" -name "appset-tools-nprod.yaml" -exec \
    sed -i "s|url: https://[0-9.]*:6443|url: https://$NPROD_IP:6443|g" {} \;
  # Atualiza todos os appset-tools-prod.yaml (destinam ao prod-bu-x)
  find "$GITOPS_GLOBAL/domains" -name "appset-tools-prod.yaml" -exec \
    sed -i "s|url: https://[0-9.]*:6443|url: https://$PROD_IP:6443|g" {} \;
  # Aplica localmente e commita/pusha para o git remoto (ArgoCD sincroniza do git)
  changed=$(cd "$GITOPS_GLOBAL" && git diff --name-only)
  if [ -n "$changed" ]; then
    (cd "$GITOPS_GLOBAL" && \
      git add domains/*/nprod/appset-tools-nprod.yaml domains/*/prod/appset-tools-prod.yaml && \
      git commit -m "fix: update cluster URLs after kind reboot (nprod=$NPROD_IP, prod=$PROD_IP)" && \
      git push origin main && \
      echo "     gitops-global → commit + push OK")
    # Forçar hard refresh nas root apps para sincronizar imediatamente
    sleep 5
    for rootapp in root-bu-x-nprod root-bu-a-nprod root-bu-b-nprod; do
      kubectl --context kind-gerencia-global annotate application "$rootapp" \
        -n argocd argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
    done
    echo "     ArgoCD hard refresh disparado"
  else
    echo "     gitops-global → sem mudança de IPs, nenhum commit necessário"
  fi
else
  warn "gitops-global não encontrado ao lado de gitops-ocm-foundation — pulando"
fi
echo ""

# ── 6. Atualizar ArgoCD cluster Secrets ────────────────────────────────────
info "Atualizando ArgoCD cluster Secrets (gerencia-global)..."

patch_argocd_secret() {
  local secret_name="$1"
  local cluster_ip="$2"
  local current_server
  current_server=$(kubectl --context kind-gerencia-global get secret "$secret_name" \
    -n argocd -o jsonpath='{.data.server}' | base64 -d 2>/dev/null || echo "")
  local new_server="https://${cluster_ip}:6443"
  if [ "$current_server" != "$new_server" ]; then
    kubectl --context kind-gerencia-global patch secret "$secret_name" \
      -n argocd -p "{\"stringData\":{\"server\":\"$new_server\"}}"
    echo "     $secret_name → $new_server"
  else
    echo "     $secret_name → $new_server (sem mudança)"
  fi
}
patch_argocd_secret "cluster-nprod-bu-x" "$NPROD_IP"
patch_argocd_secret "cluster-prod-bu-x"  "$PROD_IP"
echo ""

# ── 6. Atualizar hub kubeconfig Secrets nos add-ons de governance ───────────
info "Atualizando hub kubeconfig nos add-ons de governance..."

patch_hub_kubeconfig() {
  local ctx="$1"
  local ns="$2"
  local secret="$3"
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
    | sed "s|https://[0-9.]*:6443|https://$HUB_IP:6443|g" \
    | base64 -w 0)
  kubectl --context "$ctx" patch secret "$secret" -n "$ns" \
    -p "{\"data\":{\"kubeconfig\":\"$new_kc\"}}"
  echo "     $ctx → $secret atualizado (hub → $HUB_IP)"
}

for ctx in kind-prod-bu-x kind-nprod-bu-x; do
  patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
    "governance-policy-framework-hub-kubeconfig"
  patch_hub_kubeconfig "$ctx" "open-cluster-management-agent-addon" \
    "config-policy-controller-hub-kubeconfig"
done

# Também atualiza o hub-kubeconfig-secret no agente de cada cluster managed
for ctx in kind-prod-bu-x kind-nprod-bu-x; do
  patch_hub_kubeconfig "$ctx" "open-cluster-management-agent" "hub-kubeconfig-secret"
done
echo ""

# ── 7. Reiniciar componentes afetados ──────────────────────────────────────
info "Reiniciando componentes nos clusters managed..."
for ctx in kind-prod-bu-x kind-nprod-bu-x; do
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
done
echo ""

info "Reiniciando componentes no gerencia-global..."
kubectl --context kind-gerencia-global rollout restart ds/kube-proxy -n kube-system 2>/dev/null || true
kubectl --context kind-gerencia-global rollout restart deploy/local-path-provisioner \
  -n local-path-storage 2>/dev/null || true
kubectl --context kind-gerencia-global rollout restart deploy/klusterlet \
  -n open-cluster-management-agent 2>/dev/null || true
kubectl --context kind-gerencia-global rollout restart \
  deploy/cluster-manager-addon-manager-controller \
  deploy/cluster-manager-registration-controller \
  -n open-cluster-management-hub 2>/dev/null || true
kubectl --context kind-gerencia-global rollout restart \
  deploy/governance-policy-propagator \
  -n open-cluster-management 2>/dev/null || true
echo ""

# ── 8. Aguardar e verificar status final ───────────────────────────────────
info "Aguardando 30s para os pods subirem..."
sleep 30

echo ""
echo "════════════════════ STATUS FINAL ════════════════════"
ALL_OK=true
for ctx in kind-gerencia-global kind-prod-bu-x kind-nprod-bu-x; do
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
kubectl --context kind-gerencia-global get managedclusters
echo ""
echo "─────────────────── ArgoCD ───────────────────────────"
curl -s -o /dev/null -w "argocd.local HTTP status: %{http_code}\n" http://argocd.local 2>/dev/null \
  || warn "argocd.local inacessível via curl"
echo ""

if $ALL_OK; then
  info "Ambiente completamente restaurado! 🎉"
else
  warn "Alguns pods ainda não estão Running. Verifique os logs acima."
fi
