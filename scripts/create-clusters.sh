#!/bin/bash

# create-clusters.sh - Cria os 6 clusters Kind do ambiente corporativo
#
# Clusters:
#   gerencia-ho  → Hub de Homologação (ArgoCD + OCM Hub, portas 80/443)
#   gerencia-pr  → Hub de Produção (ArgoCD + OCM Hub, portas 8080/8443)
#   bu-a-ho      → Worker BU-A Homologação
#   bu-a-pr      → Worker BU-A Produção
#   bu-b-ho      → Worker BU-B Homologação
#   bu-b-pr      → Worker BU-B Produção
#
# Uso: ./scripts/create-clusters.sh [--only ho|pr|all]

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_CONFIGS="$REPO_ROOT/manifests/kind-configs"

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
abort() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Parse args ─────────────────────────────────────────────────────────────
SCOPE="${1:-all}"
case "$SCOPE" in
  --only) SCOPE="${2:-all}" ;;
esac

echo ""
echo "════════════════════════════════════════════════════════"
echo "   create-clusters.sh — Criando clusters Kind          "
echo "════════════════════════════════════════════════════════"
echo ""

create_cluster() {
  local name="$1"
  local config="$2"

  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    warn "Cluster '$name' já existe — pulando"
  else
    info "Criando cluster '$name'..."
    kind create cluster --name "$name" --config "$config"
    info "Cluster '$name' criado ✅"
  fi
}

# ── Criar clusters de Homologação ──────────────────────────────────────────
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  echo "── Ambiente HO (Homologação) ──────────────────────────"
  create_cluster "gerencia-ho" "$KIND_CONFIGS/kind-gerencia-ho.yaml"
  create_cluster "bu-a-ho"     "$KIND_CONFIGS/kind-bu-a-ho.yaml"
  create_cluster "bu-b-ho"     "$KIND_CONFIGS/kind-bu-b-ho.yaml"
  echo ""
fi

# ── Criar clusters de Produção ─────────────────────────────────────────────
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  echo "── Ambiente PR (Produção) ─────────────────────────────"
  create_cluster "gerencia-pr" "$KIND_CONFIGS/kind-gerencia-pr.yaml"
  create_cluster "bu-a-pr"     "$KIND_CONFIGS/kind-bu-a-pr.yaml"
  create_cluster "bu-b-pr"     "$KIND_CONFIGS/kind-bu-b-pr.yaml"
  echo ""
fi

# ── Aumentar limites de inotify ────────────────────────────────────────────
info "Ajustando limites de inotify em todos os nodes..."
for container in $(docker ps --filter "name=-control-plane" --format '{{.Names}}' | grep -E "(gerencia|bu-[ab])-(ho|pr)"); do
  docker exec "$container" sh -c \
    'grep -q "max_user_watches=524288" /etc/sysctl.conf || echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
     grep -q "max_user_instances=512" /etc/sysctl.conf  || echo "fs.inotify.max_user_instances=512"  >> /etc/sysctl.conf
     sysctl -p > /dev/null 2>&1' \
    && echo "     $container → ok"
done
echo ""

# ── Resumo ─────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
info "Clusters criados!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "📋 Clusters Kind ativos:"
kind get clusters 2>/dev/null | while read -r c; do
  echo "   • $c"
done
echo ""
echo "📋 Contextos kubectl:"
kubectl config get-contexts -o name 2>/dev/null | grep "kind-" | while read -r ctx; do
  echo "   • $ctx"
done
echo ""
echo "📋 IPs dos containers:"
for cluster in gerencia-ho gerencia-pr bu-a-ho bu-a-pr bu-b-ho bu-b-pr; do
  container="${cluster}-control-plane"
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || echo "N/A")
  printf "   %-20s → %s\n" "$cluster" "$ip"
done
echo ""
echo "🚀 Próximo passo:"
echo "   ./scripts/bootstrap.sh --env ho"
echo "   ./scripts/bootstrap.sh --env pr"
