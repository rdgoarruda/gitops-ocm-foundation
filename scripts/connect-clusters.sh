#!/bin/bash

# connect-clusters.sh - Registra os clusters nprod e prod no ArgoCD
# Usa criação direta de Secrets no namespace argocd (método mais estável)
# Pré-requisito:
#   - Cluster gerencia-global rodando com ArgoCD
#   - Clusters nprod-bu-x e prod-bu-x existentes
# Uso: ./connect-clusters.sh

set -e
export PATH=$PATH:$(pwd)/bin

# Descobrir IPs dos clusters (todos na mesma Docker network do Kind)
NPROD_IP=$(sg docker -c "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nprod-bu-x-control-plane")
PROD_IP=$(sg docker -c "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod-bu-x-control-plane")

echo "📍 IPs dos clusters:"
echo "   nprod-bu-x: $NPROD_IP"
echo "   prod-bu-x:  $PROD_IP"
echo ""

# Extrair certificados do nprod
echo "🔑 Extraindo credenciais do nprod-bu-x..."
NPROD_CERT=$(kubectl --context kind-nprod-bu-x config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
NPROD_CLIENT_CERT=$(kubectl --context kind-nprod-bu-x config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}')
NPROD_CLIENT_KEY=$(kubectl --context kind-nprod-bu-x config view --raw \
  -o jsonpath='{.users[0].user.client-key-data}')

# Extrair certificados do prod
echo "🔑 Extraindo credenciais do prod-bu-x..."
PROD_CERT=$(kubectl --context kind-prod-bu-x config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
PROD_CLIENT_CERT=$(kubectl --context kind-prod-bu-x config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}')
PROD_CLIENT_KEY=$(kubectl --context kind-prod-bu-x config view --raw \
  -o jsonpath='{.users[0].user.client-key-data}')

# Registrar nprod no ArgoCD via Secret
echo "🔗 Registrando nprod-bu-x no ArgoCD..."
kubectl --context kind-gerencia-global apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-nprod-bu-x
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: nprod-bu-x
  server: "https://${NPROD_IP}:6443"
  config: |
    {
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${NPROD_CERT}",
        "certData": "${NPROD_CLIENT_CERT}",
        "keyData": "${NPROD_CLIENT_KEY}"
      }
    }
EOF

# Registrar prod no ArgoCD via Secret
echo "🔗 Registrando prod-bu-x no ArgoCD..."
kubectl --context kind-gerencia-global apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-prod-bu-x
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: prod-bu-x
  server: "https://${PROD_IP}:6443"
  config: |
    {
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${PROD_CERT}",
        "certData": "${PROD_CLIENT_CERT}",
        "keyData": "${PROD_CLIENT_KEY}"
      }
    }
EOF

echo ""
echo "=========================================="
echo "✅ Clusters registrados no ArgoCD!"
echo "=========================================="
echo "Verifique em: http://argocd.local → Settings → Clusters"
echo ""
echo "Clusters registrados:"
kubectl --context kind-gerencia-global get secrets -n argocd \
  -l argocd.argoproj.io/secret-type=cluster \
  -o custom-columns='CLUSTER:.stringData.name,SERVER:.stringData.server'
echo ""
echo "NOTA: Os IPs acima mudam após reiniciar o Docker."
echo "      Rode este script novamente para atualizar."
