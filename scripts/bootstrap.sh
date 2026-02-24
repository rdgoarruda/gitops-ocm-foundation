#!/bin/bash

# bootstrap.sh - Configura ambiente K8s completo no cluster de gerência
#
# Instala: HAProxy + ArgoCD + Headlamp + OCM Hub (via clusteradm)
#
# Uso: ./scripts/bootstrap.sh --env ho|pr
#
# --env ho  → Bootstrapa gerencia-ho  (argocd-ho.local, porta 80)
# --env pr  → Bootstrapa gerencia-pr  (argocd-pr.local, porta 8080)
#
# Pré-requisito: clusters criados via ./scripts/create-clusters.sh

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
    *) abort "Argumento desconhecido: $1. Uso: ./bootstrap.sh --env ho|pr" ;;
  esac
done

[ -z "$ENV" ] && abort "Uso: ./bootstrap.sh --env ho|pr"
[[ "$ENV" != "ho" && "$ENV" != "pr" ]] && abort "Ambiente inválido: '$ENV'. Use 'ho' ou 'pr'."

# ── Variáveis por ambiente ─────────────────────────────────────────────────
CLUSTER_NAME="gerencia-${ENV}"
CONTEXT="kind-${CLUSTER_NAME}"
NODE_NAME="${CLUSTER_NAME}-control-plane"

if [ "$ENV" = "ho" ]; then
  ARGOCD_HOST="argocd-ho.local"
  HEADLAMP_HOST="headlamp-ho.local"
  ARGOCD_PORT="80"
else
  ARGOCD_HOST="argocd-pr.local"
  HEADLAMP_HOST="headlamp-pr.local"
  ARGOCD_PORT="8080"
fi

TOTAL_STEPS=8

echo ""
echo "════════════════════════════════════════════════════════"
echo "   bootstrap.sh — Ambiente: ${ENV^^} (${CLUSTER_NAME})"
echo "════════════════════════════════════════════════════════"
echo ""

# Verificar se o cluster existe
kubectl config use-context "$CONTEXT" 2>/dev/null \
  || abort "Contexto '$CONTEXT' não encontrado. Rode ./scripts/create-clusters.sh primeiro."

# -----------------------------------------------------------
# 1. Gateway API CRDs
# -----------------------------------------------------------
echo "📦 [1/${TOTAL_STEPS}] Instalando Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# -----------------------------------------------------------
# 2. HAProxy Ingress Controller
# -----------------------------------------------------------
echo "🛡️ [2/${TOTAL_STEPS}] Instalando HAProxy Ingress Controller..."
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts 2>/dev/null || true
helm repo update
helm upgrade --install haproxy-gateway haproxy-ingress/haproxy-ingress \
  --namespace haproxy-controller --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set "controller.nodeSelector.kubernetes\\.io/hostname=${NODE_NAME}" \
  --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set controller.tolerations[0].operator=Exists \
  --set controller.tolerations[0].effect=NoSchedule

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: haproxy
spec:
  controller: haproxy-ingress.github.io/controller
EOF

# -----------------------------------------------------------
# 3. ArgoCD
# -----------------------------------------------------------
echo "🔄 [3/${TOTAL_STEPS}] Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "   Aguardando ArgoCD iniciar..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

# Habilita modo inseguro (HTTP)
kubectl patch deployment argocd-server -n argocd --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# -----------------------------------------------------------
# 4. Headlamp (Dashboard K8s)
# -----------------------------------------------------------
echo "📊 [4/${TOTAL_STEPS}] Instalando Headlamp..."
kubectl apply -f "$REPO_ROOT/manifests/headlamp.yaml"
echo "   Aguardando Headlamp iniciar..."
kubectl rollout status deployment/headlamp -n headlamp --timeout=90s

# -----------------------------------------------------------
# 5. Ingress para ArgoCD + Headlamp
# -----------------------------------------------------------
echo "🌐 [5/${TOTAL_STEPS}] Criando Ingress para ArgoCD (${ARGOCD_HOST}) e Headlamp (${HEADLAMP_HOST})..."
kubectl apply -f - <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: haproxy
spec:
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp-ingress
  namespace: headlamp
  annotations:
    kubernetes.io/ingress.class: haproxy
spec:
  rules:
  - host: ${HEADLAMP_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: headlamp
            port:
              number: 80
EOF

# -----------------------------------------------------------
# 6. OCM Hub (via clusteradm init)
# -----------------------------------------------------------
echo "🏢 [6/${TOTAL_STEPS}] Inicializando OCM Hub (clusteradm init)..."

# Salvar token para uso posterior
OCM_TOKEN_FILE="$REPO_ROOT/.ocm-token-${ENV}"

INIT_OUTPUT=$(clusteradm init --context "$CONTEXT" --wait 2>&1)
echo "$INIT_OUTPUT"

# Extrair token do output do clusteradm init
TOKEN=$(echo "$INIT_OUTPUT" | grep -oP '(?<=--hub-token )\S+' | head -1)
if [ -z "$TOKEN" ]; then
  # Tentar obter token via clusteradm get token
  TOKEN=$(clusteradm get token --context "$CONTEXT" 2>/dev/null | grep -oP '(?<=--hub-token )\S+' | head -1)
fi

if [ -n "$TOKEN" ]; then
  echo "$TOKEN" > "$OCM_TOKEN_FILE"
  info "Token OCM salvo em $OCM_TOKEN_FILE"
else
  warn "Não conseguiu extrair token. Obtenha manualmente com: clusteradm get token --context $CONTEXT"
fi

echo "   Aguardando OCM Hub ficar pronto..."
kubectl --context "$CONTEXT" wait --for=condition=Available deployment/cluster-manager -n open-cluster-management --timeout=120s 2>/dev/null || true
sleep 10

# -----------------------------------------------------------
# 6b. Instalar Governance Policy Framework no Hub
# -----------------------------------------------------------
echo "📜 Instalando Governance Policy Framework no Hub..."
clusteradm install hub-addon --names governance-policy-framework --context "$CONTEXT" 2>&1
echo "   Aguardando governance controller ficar pronto..."
sleep 15
kubectl --context "$CONTEXT" wait --for=condition=Available deployment/governance-policy-addon-controller -n open-cluster-management --timeout=120s 2>/dev/null || true
kubectl --context "$CONTEXT" wait --for=condition=Available deployment/governance-policy-propagator -n open-cluster-management --timeout=120s 2>/dev/null || true
info "Governance Policy Framework instalado"



# -----------------------------------------------------------
# 7. Registrar Hub como ManagedCluster (auto-join)
# -----------------------------------------------------------
echo "🔗 [7/${TOTAL_STEPS}] Registrando Hub como ManagedCluster (auto-join)..."

HUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NODE_NAME")
HUB_API="https://${HUB_IP}:6443"

if [ -n "$TOKEN" ]; then
  clusteradm join \
    --hub-token "$TOKEN" \
    --hub-apiserver "$HUB_API" \
    --cluster-name in-cluster \
    --context "$CONTEXT" \
    --wait 2>&1 || warn "clusteradm join falhou, tentando aceitar mesmo assim..."

  sleep 5

  # Auto-aceitar o hub cluster
  clusteradm accept --clusters in-cluster --context "$CONTEXT" 2>/dev/null || warn "Accept in-cluster pendente"
else
  warn "Token não disponível. Registre o hub manualmente:"
  echo "   clusteradm get token --context $CONTEXT"
  echo "   clusteradm join --hub-token <TOKEN> --hub-apiserver $HUB_API --cluster-name in-cluster --context $CONTEXT"
fi

# -----------------------------------------------------------
# 8. Configurar DNS local
# -----------------------------------------------------------
echo "📡 [8/${TOTAL_STEPS}] Configurando DNS local..."

update_hosts_entry() {
  local hostname="$1"
  local new_ip="$2"
  if grep -q "$hostname" /etc/hosts 2>/dev/null; then
    current_ip=$(grep "$hostname" /etc/hosts | awk '{print $1}')
    if [ "$current_ip" != "$new_ip" ]; then
      warn "Atualizando /etc/hosts: $hostname → $new_ip (requer sudo)"
      sudo sed -i "s|^.*${hostname}|${new_ip} ${hostname}|" /etc/hosts
    else
      echo "     $hostname → $new_ip (sem mudança)"
    fi
  else
    warn "Adicionando $hostname ao /etc/hosts (requer sudo)"
    echo "$new_ip $hostname" | sudo tee -a /etc/hosts > /dev/null
  fi
}

update_hosts_entry "$ARGOCD_HOST" "$HUB_IP"
update_hosts_entry "$HEADLAMP_HOST" "$HUB_IP"

echo ""
echo "=============================================="
echo "✅ Bootstrap ${ENV^^} concluído com sucesso!"
echo "=============================================="
echo ""
echo "📋 Componentes instalados:"
echo "   ✅ HAProxy Ingress Controller"
echo "   ✅ ArgoCD"
echo "   ✅ Headlamp"
echo "   ✅ OCM Hub (clusteradm init)"
echo "   ✅ Hub auto-registrado como ManagedCluster (in-cluster)"
echo ""
echo "📋 Próximos passos:"
echo ""
echo "1. Senha inicial do ArgoCD:"
echo "   kubectl --context $CONTEXT -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
if [ "$ENV" = "ho" ]; then
  echo "2. Acesse pelo navegador:"
  echo "   ArgoCD:   http://${ARGOCD_HOST}   (usuário: admin)"
  echo "   Headlamp: http://${HEADLAMP_HOST}"
else
  echo "2. Acesse pelo navegador:"
  echo "   ArgoCD:   http://${ARGOCD_HOST}:${ARGOCD_PORT}   (usuário: admin)"
  echo "   Headlamp: http://${HEADLAMP_HOST}:${ARGOCD_PORT}"
fi
echo ""
echo "3. Conectar clusters BU (instala Headlamp + OCM Klusterlet):"
echo "   ./scripts/connect-clusters.sh --env ${ENV}"
echo "=============================================="
