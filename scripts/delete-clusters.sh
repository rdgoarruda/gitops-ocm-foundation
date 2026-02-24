#!/bin/bash

# delete-clusters.sh - Remove todos os clusters Kind do ambiente
#
# Uso: ./scripts/delete-clusters.sh [--only ho|pr]

set -e
export PATH="$PATH:$(cd "$(dirname "$0")/.." && pwd)/bin"

# ── Cores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

SCOPE="${1:-all}"
case "$SCOPE" in
  --only) SCOPE="${2:-all}" ;;
esac

echo ""
echo "════════════════════════════════════════════════════════"
echo "   delete-clusters.sh — Removendo clusters Kind        "
echo "════════════════════════════════════════════════════════"
echo ""

CLUSTERS=()
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  CLUSTERS+=(gerencia-ho bu-a-ho bu-b-ho)
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  CLUSTERS+=(gerencia-pr bu-a-pr bu-b-pr)
fi

for cluster in "${CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -q "^${cluster}$"; then
    kind delete cluster --name "$cluster"
    info "Cluster '$cluster' deletado"
  else
    warn "Cluster '$cluster' não existe — pulando"
  fi
done

echo ""

# Limpar /etc/hosts
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "ho" ]; then
  sudo sed -i '/argocd-ho.local/d' /etc/hosts 2>/dev/null || true
  sudo sed -i '/headlamp-ho.local/d' /etc/hosts 2>/dev/null || true
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "pr" ]; then
  sudo sed -i '/argocd-pr.local/d' /etc/hosts 2>/dev/null || true
  sudo sed -i '/headlamp-pr.local/d' /etc/hosts 2>/dev/null || true
fi

info "Entradas removidas do /etc/hosts"
echo ""
echo "════════════════════════════════════════════════════════"
info "Limpeza concluída!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "Clusters restantes:"
kind get clusters 2>/dev/null || echo "   (nenhum)"
