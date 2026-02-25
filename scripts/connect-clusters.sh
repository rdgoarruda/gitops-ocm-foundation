#!/bin/bash

# connect-clusters.sh - Conecta os clusters BU ao Hub via OCM + ArgoCD
#
# Para cada cluster worker (bu-a, bu-b) do ambiente:
#   1. Registra no ArgoCD do hub (via cluster Secret)
#   2. Aplica CoreDNS patch (resolve hostname do hub)
#   3. Instala Headlamp
#   4. Registra no OCM via clusteradm join
#   5. Aceita o cluster no OCM Hub
#   6. Habilita addons de governança
#
# Uso: ./scripts/connect-clusters.sh --env ho|pr

set -e
export PATH=$PATH:$(cd "$(dirname "$0")/.." && pwd)/bin

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
abort() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Parse args ─────────────────────────────────────────────────────────────
ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    *) abort "Argumento desconhecido: $1. Uso: ./connect-clusters.sh --env ho|pr" ;;
  esac
done

[ -z "$ENV" ] && abort "Uso: ./connect-clusters.sh --env ho|pr"
[[ "$ENV" != "ho" && "$ENV" != "pr" ]] && abort "Ambiente inválido: '$ENV'. Use 'ho' ou 'pr'."

# ── Variáveis por ambiente ─────────────────────────────────────────────────
HUB_NAME="gerencia-${ENV}"
HUB_CONTEXT="kind-${HUB_NAME}"
HUB_NODE="${HUB_NAME}-control-plane"
WORKERS=("bu-a-${ENV}" "bu-b-${ENV}")

echo ""
echo "════════════════════════════════════════════════════════"
echo "   connect-clusters.sh — Ambiente: ${ENV^^}"
echo "   Hub: ${HUB_NAME}"
echo "   Workers: ${WORKERS[*]}"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Detectar IPs e Token ──────────────────────────────────────────────────
get_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${1}-control-plane" 2>/dev/null \
    || abort "Container '${1}-control-plane' não encontrado."
}

HUB_IP=$(get_ip "$HUB_NAME")
HUB_API="https://${HUB_IP}:6443"
info "Hub IP ($HUB_NAME): $HUB_IP — API: $HUB_API"

# Obter token do OCM Hub
OCM_TOKEN_FILE="$REPO_ROOT/.ocm-token-${ENV}"
if [ -f "$OCM_TOKEN_FILE" ]; then
  TOKEN=$(cat "$OCM_TOKEN_FILE")
  info "Token OCM lido de $OCM_TOKEN_FILE"
else
  warn "Token file não encontrado. Obtendo via clusteradm..."
  TOKEN_OUTPUT=$(clusteradm get token --context "$HUB_CONTEXT" 2>/dev/null)
  TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oP '(?<=--hub-token )\S+' | head -1)
  if [ -z "$TOKEN" ]; then
    abort "Não foi possível obter o token do OCM Hub. Rode bootstrap.sh --env ${ENV} primeiro."
  fi
fi
echo ""

# ── Processar cada worker ──────────────────────────────────────────────────
for worker in "${WORKERS[@]}"; do
  WORKER_IP=$(get_ip "$worker")
  WORKER_CONTEXT="kind-${worker}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  📦 Configurando ${worker} (IP: ${WORKER_IP})"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ── 1. Registrar no ArgoCD ─────────────────────────────────────────────
  info "[1/5] Registrando ${worker} no ArgoCD..."
  ca_cert=$(kubectl --context "$WORKER_CONTEXT" config view --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  client_cert=$(kubectl --context "$WORKER_CONTEXT" config view --raw \
    -o jsonpath='{.users[0].user.client-certificate-data}')
  client_key=$(kubectl --context "$WORKER_CONTEXT" config view --raw \
    -o jsonpath='{.users[0].user.client-key-data}')

  kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${worker}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${worker}
  server: "https://${WORKER_IP}:6443"
  config: |
    {
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca_cert}",
        "certData": "${client_cert}",
        "keyData": "${client_key}"
      }
    }
EOF
  info "ArgoCD cluster secret criado ✅"

  # ── 2. CoreDNS patch ───────────────────────────────────────────────────
  COREDNS_FILE="$REPO_ROOT/manifests/ocm-configs/coredns-patches/coredns-${worker}.yaml"
  if [ -f "$COREDNS_FILE" ]; then
    info "[2/5] Aplicando CoreDNS patch..."
    sed -i "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ ${HUB_NODE}|${HUB_IP} ${HUB_NODE}|g" "$COREDNS_FILE"
    kubectl --context "$WORKER_CONTEXT" apply -f "$COREDNS_FILE"
    kubectl --context "$WORKER_CONTEXT" rollout restart deploy/coredns -n kube-system
    info "CoreDNS atualizado → ${HUB_NODE} = ${HUB_IP} ✅"
  else
    warn "[2/5] CoreDNS patch não encontrado: $COREDNS_FILE — pulando"
  fi

  # ── 3. Headlamp ────────────────────────────────────────────────────────
  info "[3/5] Instalando Headlamp..."
  kubectl --context "$WORKER_CONTEXT" apply -f "$REPO_ROOT/manifests/headlamp.yaml"
  echo "   Aguardando Headlamp iniciar..."
  kubectl --context "$WORKER_CONTEXT" rollout status deployment/headlamp -n headlamp --timeout=90s
  
  # Criar token permanente para o ServiceAccount headlamp-admin
  echo "   Criando token permanente para acesso..."
  kubectl --context "$WORKER_CONTEXT" apply -f - <<HEADLAMP_TOKEN
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: headlamp
  annotations:
    kubernetes.io/service-account.name: headlamp-admin
type: kubernetes.io/service-account-token
HEADLAMP_TOKEN

  # Aguardar token ser criado
  sleep 3

  # Salvar token em arquivo para facilitar acesso
  HEADLAMP_TOKEN=$(kubectl --context "$WORKER_CONTEXT" get secret headlamp-admin-token -n headlamp -o jsonpath='{.data.token}' | base64 -d)
  echo "$HEADLAMP_TOKEN" > "$REPO_ROOT/vault/headlamp-token-${worker}"
  info "Token do Headlamp salvo em vault/headlamp-token-${worker}"
  info "Headlamp instalado ✅"

  # ── 4. OCM — Registrar via clusteradm join ─────────────────────────────
  info "[4/5] Registrando ${worker} no OCM Hub (clusteradm join)..."
  clusteradm join \
    --hub-token "$TOKEN" \
    --hub-apiserver "$HUB_API" \
    --cluster-name "$worker" \
    --context "$WORKER_CONTEXT" \
    --force-internal-endpoint-lookup \
    --wait 2>&1 || warn "clusteradm join pode ter falhado — verifique manualmente"

  info "OCM Klusterlet instalado ✅"
  echo ""
done

# ── Aguardar e aceitar clusters ────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
info "Aguardando klusterlets se registrarem..."
echo "════════════════════════════════════════════════════════"
echo ""

echo "Aguardando 30s para os agentes se conectarem..."
sleep 30

# Auto-aprovar CSRs pendentes
info "Aprovando CSRs pendentes..."
PENDING_CSRS=$(kubectl --context "$HUB_CONTEXT" get csr --no-headers 2>/dev/null | grep -i pending | awk '{print $1}' || true)
if [ -n "$PENDING_CSRS" ]; then
  for csr in $PENDING_CSRS; do
    kubectl --context "$HUB_CONTEXT" certificate approve "$csr" 2>/dev/null || true
    echo "   Aprovado: $csr"
  done
else
  warn "Nenhum CSR pendente encontrado. Os clusters podem já ter sido aceitos automaticamente."
fi
echo ""

# Aceitar clusters via clusteradm
info "Aceitando clusters no OCM Hub..."
WORKER_LIST=$(IFS=,; echo "${WORKERS[*]}")
clusteradm accept --clusters "$WORKER_LIST" --context "$HUB_CONTEXT" 2>/dev/null || {
  warn "clusteradm accept falhou. Os clusters podem precisar de mais tempo."
  echo "   Tente manualmente:"
  echo "   clusteradm accept --clusters $WORKER_LIST --context $HUB_CONTEXT"
}
echo ""

# ── Habilitar addons de governança ─────────────────────────────────────────
info "Habilitando addons de governança nos workers..."
sleep 5
for worker in "${WORKERS[@]}"; do
  clusteradm addon enable --names governance-policy-framework \
    --clusters "$worker" --context "$HUB_CONTEXT" 2>/dev/null || warn "Addon governance falhou para $worker"
  clusteradm addon enable --names config-policy-controller \
    --clusters "$worker" --context "$HUB_CONTEXT" 2>/dev/null || warn "Addon config-policy falhou para $worker"
  info "Addons habilitados para $worker"
done

# Habilitar governance no hub (in-cluster) também
clusteradm addon enable --names governance-policy-framework \
  --annotate addon.open-cluster-management.io/on-multicluster-hub=true \
  --clusters in-cluster --context "$HUB_CONTEXT" 2>/dev/null || warn "Addon governance no hub falhou"
clusteradm addon enable --names config-policy-controller \
  --clusters in-cluster --context "$HUB_CONTEXT" 2>/dev/null || warn "Addon config-policy no hub falhou"
info "Addons de governança habilitados no hub (in-cluster)"
echo ""

# ── Labelar clusters ──────────────────────────────────────────────────────
info "Aplicando labels nos ManagedClusters..."
for worker in "${WORKERS[@]}"; do
  # Extrair BU do nome (bu-a-ho → bu-a, bu-b-pr → bu-b)
  BU="${worker%-*}"
  kubectl --context "$HUB_CONTEXT" label managedcluster "$worker" \
    env="$ENV" bu="$BU" --overwrite 2>/dev/null || warn "Labels para $worker pendente"
done

# Criar ManagedClusterSet
kubectl --context "$HUB_CONTEXT" apply -f - <<EOF 2>/dev/null || true
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: global
EOF

for worker in "${WORKERS[@]}"; do
  kubectl --context "$HUB_CONTEXT" label managedcluster "$worker" \
    cluster.open-cluster-management.io/clusterset=global --overwrite 2>/dev/null || true
done
info "Labels e ClusterSet aplicados ✅"
echo ""

# ── Resumo final ───────────────────────────────────────────────────────────
echo "=========================================="
echo "✅ Workers configurados (${ENV^^})!"
echo "=========================================="
echo ""
for worker in "${WORKERS[@]}"; do
  echo "   📦 ${worker}:"
  echo "      ✅ ArgoCD cluster secret"
  echo "      ✅ CoreDNS (resolve hub)"
  echo "      ✅ Headlamp (token: vault/headlamp-token-${worker})"
  echo "      ✅ OCM ManagedCluster (clusteradm join)"
  echo "      ✅ Governance Policy Framework addon"
  echo "      ✅ Config Policy Controller addon"
  echo ""
done
echo "🔐 Tokens de acesso Headlamp salvos em vault/"
echo ""
echo "Verifique o status do OCM:"
echo "   kubectl --context $HUB_CONTEXT get managedclusters"
echo ""
echo "Verifique no ArgoCD:"
if [ "$ENV" = "ho" ]; then
  echo "   http://argocd-ho.local → Settings → Clusters"
else
  echo "   http://argocd-pr.local:8080 → Settings → Clusters"
fi
echo ""
echo "NOTA: Os IPs mudam após reiniciar o Docker."
echo "      Rode ./scripts/fix-ips.sh para atualizar."
