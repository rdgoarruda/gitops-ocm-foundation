#!/bin/bash

# update-credentials.sh - Atualiza credenciais ArgoCD e tokens Headlamp
#
# Configura:
#   - ArgoCD: admin/admin nos hubs (gerencia-ho, gerencia-pr)
#   - Headlamp: tokens permanentes em todos os clusters
#
# Uso: ./scripts/update-credentials.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH=$PATH:$REPO_ROOT/bin

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
abort() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo ""
echo "════════════════════════════════════════════════════════"
echo "   update-credentials.sh — Atualizando credenciais"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Clusters ───────────────────────────────────────────────────────────────
HUB_CLUSTERS=("gerencia-ho" "gerencia-pr")
ALL_CLUSTERS=("gerencia-ho" "gerencia-pr" "bu-a-ho" "bu-a-pr" "bu-b-ho" "bu-b-pr")

# Verificar se os clusters existem
echo "📋 Verificando clusters Kind..."
EXISTING_CLUSTERS=$(kind get clusters 2>/dev/null || echo "")
if [ -z "$EXISTING_CLUSTERS" ]; then
  abort "Nenhum cluster Kind encontrado. Execute ./scripts/create-clusters.sh primeiro."
fi
echo "$EXISTING_CLUSTERS" | while read -r c; do echo "   ✓ $c"; done
echo ""

# ══════════════════════════════════════════════════════════════════════════
# 1. ATUALIZAR ARGOCD (admin/admin)
# ══════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 Atualizando senha ArgoCD → admin/admin"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for hub in "${HUB_CLUSTERS[@]}"; do
  context="kind-${hub}"
  
  # Verificar se o cluster existe
  if ! echo "$EXISTING_CLUSTERS" | grep -q "^${hub}$"; then
    warn "Cluster $hub não encontrado — pulando"
    continue
  fi
  
  # Verificar se ArgoCD está instalado
  if ! kubectl --context "$context" get namespace argocd &>/dev/null; then
    warn "ArgoCD não instalado em $hub — pulando"
    continue
  fi
  
  info "Atualizando ArgoCD em $hub..."
  ARGOCD_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'admin', bcrypt.gensalt(rounds=10)).decode())")
  kubectl --context "$context" patch secret argocd-secret -n argocd --type=merge \
    -p="{\"stringData\":{\"admin.password\":\"${ARGOCD_HASH}\",\"admin.passwordMtime\":\"$(date +%FT%T%Z)\"}}" \
    2>/dev/null || warn "Falha ao atualizar secret argocd-secret"
  
  # Deletar o secret inicial se existir
  kubectl --context "$context" delete secret argocd-initial-admin-secret -n argocd 2>/dev/null || true
  
  # Reiniciar ArgoCD server
  kubectl --context "$context" rollout restart deployment/argocd-server -n argocd 2>/dev/null
  
  info "ArgoCD em $hub atualizado → admin/admin ✅"
  echo ""
done

# ══════════════════════════════════════════════════════════════════════════
# 2. CRIAR TOKENS HEADLAMP
# ══════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Criando tokens permanentes Headlamp"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Criar diretório vault se não existir
mkdir -p "$REPO_ROOT/vault"

for cluster in "${ALL_CLUSTERS[@]}"; do
  context="kind-${cluster}"
  
  # Verificar se o cluster existe
  if ! echo "$EXISTING_CLUSTERS" | grep -q "^${cluster}$"; then
    warn "Cluster $cluster não encontrado — pulando"
    continue
  fi
  
  # Verificar se Headlamp está instalado
  if ! kubectl --context "$context" get namespace headlamp &>/dev/null; then
    warn "Headlamp não instalado em $cluster — pulando"
    continue
  fi
  
  info "Criando token Headlamp para $cluster..."
  
  # Criar secret para token permanente
  kubectl --context "$context" apply -f - <<EOF 2>/dev/null || warn "Falha ao criar secret de token"
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: headlamp
  annotations:
    kubernetes.io/service-account.name: headlamp-admin
type: kubernetes.io/service-account-token
EOF
  
  # Aguardar o token ser criado
  sleep 2
  
  # Extrair token
  TOKEN=$(kubectl --context "$context" get secret headlamp-admin-token -n headlamp \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  
  if [ -n "$TOKEN" ]; then
    # Determinar nome do arquivo baseado no ambiente
    if [[ "$cluster" == "gerencia-ho" ]]; then
      TOKEN_FILE="$REPO_ROOT/vault/headlamp-token-ho"
    elif [[ "$cluster" == "gerencia-pr" ]]; then
      TOKEN_FILE="$REPO_ROOT/vault/headlamp-token-pr"
    else
      TOKEN_FILE="$REPO_ROOT/vault/headlamp-token-${cluster}"
    fi
    
    echo "$TOKEN" > "$TOKEN_FILE"
    info "Token Headlamp salvo → $(basename $TOKEN_FILE) ✅"
  else
    warn "Não foi possível extrair token para $cluster"
  fi
  echo ""
done

# ══════════════════════════════════════════════════════════════════════════
# 3. RESUMO FINAL
# ══════════════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════"
echo "✅ Credenciais atualizadas com sucesso!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "🔐 ArgoCD (gerencia-ho, gerencia-pr):"
echo "   Usuário: admin"
echo "   Senha:   admin"
echo ""
echo "📊 Headlamp (todos os clusters):"
echo "   Tokens salvos em vault/:"
ls -1 "$REPO_ROOT/vault/headlamp-token-"* 2>/dev/null | while read -r f; do
  echo "      • $(basename "$f")"
done
echo ""
echo "🌐 URLs de acesso:"
echo "   ArgoCD HO:  http://argocd-ho.local"
echo "   ArgoCD PR:  http://argocd-pr.local:8080"
echo ""
echo "📋 Port-forward para Headlamp (BUs):"
echo "   kubectl port-forward -n headlamp svc/headlamp 8081:80 --context kind-bu-a-ho"
echo "   kubectl port-forward -n headlamp svc/headlamp 8082:80 --context kind-bu-a-pr"
echo "   kubectl port-forward -n headlamp svc/headlamp 8083:80 --context kind-bu-b-ho"
echo "   kubectl port-forward -n headlamp svc/headlamp 8084:80 --context kind-bu-b-pr"
echo ""
echo "📖 Documentação completa: vault/README-CREDENTIALS.md"
echo "════════════════════════════════════════════════════════"
