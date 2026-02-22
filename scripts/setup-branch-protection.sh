#!/bin/bash

# =================================================================
# setup-branch-protection.sh
#
# Configura branch protection rules nos 3 repositórios GitOps
# para que apenas @rdgoarruda possa fazer merge na branch main.
#
# Pré-requisitos:
#   - GitHub CLI (gh) instalado e autenticado: gh auth login
#   - Ser admin dos repositórios
#
# Uso: ./scripts/setup-branch-protection.sh
# =================================================================

set -e

GITHUB_USER="rdgoarruda"
REPOS=(
  "${GITHUB_USER}/gitops-ocm-foundation"
  "${GITHUB_USER}/gitops-global"
  "${GITHUB_USER}/gitops-bu"
)

echo "🔒 Configurando branch protection para a branch 'main'..."
echo ""

for REPO in "${REPOS[@]}"; do
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 Repositório: ${REPO}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # -------------------------------------------------------
  # Opção 1: Rulesets (GitHub moderno — recomendado)
  # Funciona em repos free + pro + enterprise
  # -------------------------------------------------------
  echo "  → Criando ruleset via API..."

  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "/repos/${REPO}/rulesets" \
    -f name="protect-main" \
    -f target="branch" \
    -f enforcement="active" \
    -f 'conditions[ref_name][include][]=refs/heads/main' \
    -f 'conditions[ref_name][exclude]=[]' \
    --input - <<EOF
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "deletion"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "required_linear_history"
    }
  ],
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ]
}
EOF

  if [ $? -eq 0 ]; then
    echo "  ✅ Ruleset criado com sucesso!"
  else
    echo "  ⚠️  Falha ao criar ruleset. Tentando branch protection clássico..."

    # -------------------------------------------------------
    # Opção 2: Branch Protection clássico (fallback)
    # -------------------------------------------------------
    gh api \
      --method PUT \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/branches/main/protection" \
      --input - <<CLASSIC
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1,
    "bypass_pull_request_allowances": {
      "users": ["${GITHUB_USER}"]
    }
  },
  "restrictions": {
    "users": ["${GITHUB_USER}"],
    "teams": []
  },
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
CLASSIC

    if [ $? -eq 0 ]; then
      echo "  ✅ Branch protection clássico aplicado!"
    else
      echo "  ❌ Falha. Verifique se você é admin do repositório ${REPO}."
    fi
  fi

  echo ""
done

echo "=========================================="
echo "🔒 Configuração concluída!"
echo "=========================================="
echo ""
echo "Regras aplicadas na branch 'main':"
echo "  ✅ Require pull request antes de merge"
echo "  ✅ Require 1 approval de CODEOWNERS (@${GITHUB_USER})"
echo "  ✅ Dismiss stale reviews on push"
echo "  ✅ Impedir deletion da branch"
echo "  ✅ Impedir force-push"
echo "  ✅ Require linear history (squash/rebase)"
echo ""
echo "📝 CODEOWNERS configurados em todos os repos com:"
echo "   * @${GITHUB_USER}"
echo ""
echo "Verifique em:"
echo "  https://github.com/${REPOS[0]}/settings/rules"
echo "  https://github.com/${REPOS[1]}/settings/rules"
echo "  https://github.com/${REPOS[2]}/settings/rules"
