#!/bin/bash

# bootstrap.sh - Configura ambiente K8s isolado com Kind
# Uso: ./bootstrap.sh
# Pré-requisito: cluster Kind criado via `kind create cluster --config kind-config.yaml`

set -e
export PATH=$PATH:$(pwd)/bin

echo "🚀 Iniciando Bootstrap do ambiente..."

# -----------------------------------------------------------
# 1. Gateway API CRDs
# -----------------------------------------------------------
echo "📦 [1/5] Instalando Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# -----------------------------------------------------------
# 2. HAProxy Ingress Controller
# Notas:
#   - hostNetwork=true: permite bind na porta 80/443 do nó
#   - dnsPolicy=ClusterFirstWithHostNet: mantém resolução de DNS do cluster
#   - nodeSelector: fixa no control-plane (que tem as portas 80/443 mapeadas via kind-config.yaml)
#   - tolerations: permite rodar no control-plane (que tem taint NoSchedule)
# -----------------------------------------------------------
echo "🛡️ [2/5] Instalando HAProxy Ingress Controller..."
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts 2>/dev/null || true
helm repo update
helm upgrade --install haproxy-gateway haproxy-ingress/haproxy-ingress \
  --namespace haproxy-controller --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set "controller.nodeSelector.kubernetes\\.io/hostname=gerencia-global-control-plane" \
  --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set controller.tolerations[0].operator=Exists \
  --set controller.tolerations[0].effect=NoSchedule

# IngressClass para que o HAProxy reconheça Ingress com ingressClassName: haproxy
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
# Nota: --insecure desativa o redirect HTTPS para funcionar via Ingress HTTP
# -----------------------------------------------------------
echo "🔄 [3/5] Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "   Aguardando ArgoCD iniciar..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

# Habilita modo inseguro (HTTP) para permitir acesso via Ingress simples
kubectl patch deployment argocd-server -n argocd --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# -----------------------------------------------------------
# 5. Expondo ferramentas via Ingress (HAProxy)
# Nota: usar annotation 'kubernetes.io/ingress.class' (não ingressClassName)
# pois o haproxy-ingress v0.15 faz match pela annotation direto
# -----------------------------------------------------------
echo "🌐 [5/5] Criando Ingress para ferramentas..."
kubectl apply -f manifests/ingress-setup.yaml

echo ""
echo "=============================================="
echo "✅ Bootstrap concluído com sucesso!"
echo "=============================================="
echo ""
echo "📋 Próximos passos:"
echo ""
echo "1. Adicione ao seu /etc/hosts:"
echo "   $(kubectl get nodes gerencia-global-control-plane -o jsonpath='{.status.addresses[0].address}') argocd.local"
echo ""
echo "2. Senha inicial do ArgoCD:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "3. Acesse pelo navegador:"
echo "   http://argocd.local   (usuário: admin)"
echo "=============================================="
