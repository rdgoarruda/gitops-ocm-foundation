# gitops-ocm-foundation

Repositório de **fundação e bootstrap** para replicar o ambiente multi-cluster local com Kind, ArgoCD e Open Cluster Management (OCM). Este ambiente permite testar os repositórios [`gitops-global`](https://github.com/rdgoarruda/gitops-global) (governança/políticas) e [`gitops-bu`](https://github.com/rdgoarruda/gitops-bu) (ferramentas de BU) em um lab local.

---

## Visão Geral da Arquitetura

```
┌─────────────────────────────────────────────────────────────────────┐
│                        REPOSITÓRIOS GIT                            │
│                                                                     │
│  gitops-ocm-foundation    gitops-global         gitops-bu           │
│  (este repo)              (políticas OCM)       (tools da BU)       │
│  └─ bootstrap do lab      └─ governance/*       └─ nprod/tools/*    │
│                            └─ config/*           └─ prod/tools/*    │
│                            └─ domains/bu-x/*                        │
└─────────────┬──────────────────────┬────────────────────┬───────────┘
              │                      │                    │
              ▼                      ▼                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│               gerencia-global (Hub)                                 │
│               ├── ArgoCD          → sincroniza todos os repos       │
│               ├── OCM Hub         → distribui políticas             │
│               └── OCM Klusterlet  → auto-registrado como worker     │
├─────────────────────────────────────────────────────────────────────┤
│               nprod-bu-x (Worker)                                   │
│               ├── OCM Klusterlet  → agente do Hub                   │
│               ├── label: env=nprod                                  │
│               └── recebe: políticas OCM + tools da BU               │
├─────────────────────────────────────────────────────────────────────┤
│               prod-bu-x (Worker)                                    │
│               ├── OCM Klusterlet  → agente do Hub                   │
│               ├── label: env=prod                                   │
│               └── recebe: políticas OCM + tools da BU               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Estrutura do Repositório

```
gitops-ocm-foundation/
├── scripts/
│   ├── bootstrap.sh              # Instala HAProxy + ArgoCD no cluster Hub
│   ├── connect-clusters.sh       # Registra clusters worker no ArgoCD (Secrets)
│   ├── install_docker.sh         # Instala Docker no Ubuntu/Debian
│   └── k8s_env.sh               # Exporta PATH com binários locais
├── manifests/
│   ├── headlamp.yaml             # Dashboard Kubernetes (opcional)
│   ├── kind-configs/
│   │   ├── kind-gerencia.yaml    # Config Kind — cluster Hub (portas 80/443)
│   │   ├── kind-nprod.yaml       # Config Kind — cluster nprod-bu-x
│   │   ├── kind-prod.yaml        # Config Kind — cluster prod-bu-x
│   │   ├── ingress-setup.yaml    # Ingress para ArgoCD (argocd.local)
│   │   └── expose-tool.yaml      # Template para expor novas ferramentas
│   └── ocm-configs/
│       ├── argocd-apps/
│       │   ├── 01-ocm-hub.yaml                      # ArgoCD App → OCM Hub (cluster-manager)
│       │   ├── 02-ocm-klusterlet-hub.yaml            # ArgoCD App → Klusterlet no Hub
│       │   ├── 03-ocm-klusterlet-nprod.yaml          # ArgoCD App → Klusterlet em nprod
│       │   ├── 04-ocm-klusterlet-prod.yaml           # ArgoCD App → Klusterlet em prod
│       │   └── ocm-governance-policy-framework.yaml  # ArgoCD App → Policy Framework addon
│       ├── argocd-cluster-secrets/
│       │   ├── argocd-secret-nprod-bu-x.yaml         # Secret para ArgoCD acessar nprod
│       │   └── argocd-secret-prod-bu-x.yaml          # Secret para ArgoCD acessar prod
│       └── coredns-patches/
│           ├── coredns-nprod-bu-x.yaml               # DNS fix para nprod resolver o Hub
│           └── coredns-prod-bu-x.yaml                # DNS fix para prod resolver o Hub
├── docs/
│   ├── ADR-001-three-repo-gitops-strategy.md
│   ├── ADR-002-single-branch-environment-per-directory.md
│   ├── ADR-003-ocm-over-rhacm.md
│   └── ADR-004-argocd-as-delivery-tool.md
└── 01.repos-organization/
    └── prompts.md                # Contexto original das decisões
```

---

## Pré-requisitos

| Ferramenta | Versão mínima | Finalidade |
|---|---|---|
| **Docker** | 24+ | Runtime dos containers Kind |
| **kind** | 0.20+ | Cria clusters K8s locais |
| **kubectl** | 1.28+ | CLI Kubernetes |
| **helm** | 3.12+ | Instalação do HAProxy Ingress |
| **clusteradm** | 0.8+ | CLI do OCM para aceitar clusters |
| **argocd** (CLI) | 2.9+ | (Opcional) gerenciar ArgoCD via terminal |

### Instalação rápida dos binários

```bash
# Docker (Ubuntu/Debian)
./scripts/install_docker.sh

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# clusteradm
curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash
```

---

## Guia Passo a Passo — Replicação Completa

### Fase 1 — Criar os 3 Clusters Kind

```bash
cd gitops-ocm-foundation

# 1. Cluster Hub (gerência) — com portas 80/443 mapeadas para Ingress
kind create cluster --name gerencia-global --config manifests/kind-configs/kind-gerencia.yaml

# 2. Cluster nprod (worker)
kind create cluster --name nprod-bu-x --config manifests/kind-configs/kind-nprod.yaml

# 3. Cluster prod (worker)
kind create cluster --name prod-bu-x --config manifests/kind-configs/kind-prod.yaml
```

**Verificação:**
```bash
kind get clusters
# Esperado:
#   gerencia-global
#   nprod-bu-x
#   prod-bu-x

kubectl config get-contexts
# Deve listar: kind-gerencia-global, kind-nprod-bu-x, kind-prod-bu-x
```

---

### Fase 2 — Bootstrap do Hub (HAProxy + ArgoCD)

```bash
# Mudar para o contexto do Hub
kubectl config use-context kind-gerencia-global

# Executar o bootstrap
./scripts/bootstrap.sh
```

O script instala:
1. **Gateway API CRDs**
2. **HAProxy Ingress Controller** — bound nas portas 80/443 do nó control-plane
3. **ArgoCD** — com modo inseguro (HTTP) para funcionar via Ingress
4. **Ingress** — `argocd.local` apontando para o ArgoCD

**Configurar DNS local:**
```bash
# Descobrir IP do control-plane
HUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gerencia-global-control-plane)
echo "$HUB_IP argocd.local" | sudo tee -a /etc/hosts
```

**Obter senha do ArgoCD:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
# Usuário: admin
# Acesse: http://argocd.local
```

---

### Fase 3 — Registrar Clusters Worker no ArgoCD

```bash
kubectl config use-context kind-gerencia-global
./scripts/connect-clusters.sh
```

O script automaticamente:
- Descobre os IPs dos containers Docker de `nprod-bu-x` e `prod-bu-x`
- Extrai certificados TLS de cada cluster
- Cria Secrets do tipo `argocd.argoproj.io/secret-type: cluster` no namespace `argocd`

**Verificação:**
```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
# Deve listar: cluster-nprod-bu-x, cluster-prod-bu-x
```

Ou acesse: http://argocd.local → **Settings** → **Clusters**

---

### Fase 4 — Instalar OCM (Hub + Klusterlets)

#### 4.1 — Instalar OCM Hub + Klusterlet do Hub

```bash
kubectl config use-context kind-gerencia-global

kubectl apply -f manifests/ocm-configs/argocd-apps/01-ocm-hub.yaml
kubectl apply -f manifests/ocm-configs/argocd-apps/02-ocm-klusterlet-hub.yaml
```

Aguardar até o ArgoCD sincronizar (verifique em http://argocd.local).

#### 4.2 — Corrigir DNS nos Workers

Os clusters worker precisam resolver `gerencia-global-control-plane` (hostname Docker do Hub).

> ⚠️ Verifique se o IP `172.18.0.2` nos arquivos corresponde ao IP real do Hub. Caso contrário, edite os arquivos `coredns-*.yaml`.

```bash
# Descobrir IP real do Hub
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gerencia-global-control-plane

# Aplicar patches de DNS
kubectl --context kind-nprod-bu-x apply -f manifests/ocm-configs/coredns-patches/coredns-nprod-bu-x.yaml
kubectl --context kind-nprod-bu-x rollout restart deploy/coredns -n kube-system

kubectl --context kind-prod-bu-x apply -f manifests/ocm-configs/coredns-patches/coredns-prod-bu-x.yaml
kubectl --context kind-prod-bu-x rollout restart deploy/coredns -n kube-system
```

#### 4.3 — Instalar Klusterlets nos Workers

```bash
kubectl config use-context kind-gerencia-global

kubectl apply -f manifests/ocm-configs/argocd-apps/03-ocm-klusterlet-nprod.yaml
kubectl apply -f manifests/ocm-configs/argocd-apps/04-ocm-klusterlet-prod.yaml
```

#### 4.4 — Aprovar CSRs e Aceitar Clusters

Quando os Klusterlets iniciam pela primeira vez, enviam um Certificate Signing Request ao Hub.

```bash
kubectl config use-context kind-gerencia-global

# Aguardar CSRs aparecerem (pode levar 1-2 minutos)
kubectl get csr -w

# Aprovar CSRs pendentes
csr_nprod=$(kubectl get csr | grep nprod-bu-x | grep Pending | awk '{print $1}')
csr_prod=$(kubectl get csr | grep prod-bu-x | grep Pending | awk '{print $1}')
kubectl certificate approve $csr_nprod $csr_prod

# Aceitar os clusters no OCM Hub
clusteradm accept --clusters nprod-bu-x,prod-bu-x
```

#### 4.5 — Instalar Policy Framework (Governance)

```bash
kubectl apply -f manifests/ocm-configs/argocd-apps/ocm-governance-policy-framework.yaml
```

**Verificação final do OCM:**
```bash
kubectl get managedclusters
# Esperado:
# NAME          HUB ACCEPTED   MANAGED CLUSTER URLS          JOINED   AVAILABLE
# in-cluster    true           https://kubernetes.default...  True     True
# nprod-bu-x    true           https://172.18.0.x:6443       True     True
# prod-bu-x     true           https://172.18.0.x:6443       True     True
```

---

### Fase 5 — Testar o Repositório `gitops-global`

O `gitops-global` contém a governança OCM e o bootstrap que auto-descobre políticas.

#### 5.1 — Labelar Clusters para Placement

```bash
kubectl config use-context kind-gerencia-global

kubectl label managedcluster nprod-bu-x env=nprod --overwrite
kubectl label managedcluster prod-bu-x env=prod --overwrite

# Criar ManagedClusterSet e adicionar clusters
kubectl apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: global
EOF

kubectl label managedcluster nprod-bu-x cluster.open-cluster-management.io/clusterset=global --overwrite
kubectl label managedcluster prod-bu-x cluster.open-cluster-management.io/clusterset=global --overwrite
```

#### 5.2 — Aplicar Bootstrap do gitops-global

```bash
kubectl config use-context kind-gerencia-global

# Bootstrap nprod (App-of-Apps)
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bootstrap-nprod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/rdgoarruda/gitops-global.git'
    targetRevision: main
    path: bootstrap/nprod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
EOF

# Bootstrap prod (App-of-Apps)
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bootstrap-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/rdgoarruda/gitops-global.git'
    targetRevision: main
    path: bootstrap/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
EOF
```

O ArgoCD automaticamente vai:
1. Criar as Applications `ocm-config-nprod` e `ocm-config-prod` (Namespace, Placement, Bindings)
2. Criar o ApplicationSet `governance-*` que varre `governance/*` e cria uma Application por categoria (security, platform, observability, capacity, compliance, infrastructure)
3. O OCM distribui as políticas para os clusters via PlacementBinding

**Verificação:**
```bash
# Applications criadas pelo ArgoCD
kubectl -n argocd get applications

# Políticas OCM distribuídas
kubectl get policies -A

# Status de compliance nos clusters
kubectl get policies -A -o custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,REMEDIATION:.spec.remediationAction,COMPLIANT:.status.compliant'
```

---

### Fase 6 — Testar o Repositório `gitops-bu`

O `gitops-bu` é gerenciado indiretamente pelo `gitops-global` via `domains/bu-x/`.

#### 6.1 — Aplicar Bootstrap da BU

```bash
kubectl config use-context kind-gerencia-global

# Bootstrap BU nprod
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bu-x-nprod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/rdgoarruda/gitops-global.git'
    targetRevision: main
    path: domains/bu-x/nprod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF

# Bootstrap BU prod
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bu-x-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/rdgoarruda/gitops-global.git'
    targetRevision: main
    path: domains/bu-x/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF
```

O ApplicationSet `bu-tools-nprod` vai:
- Varrer `nprod/tools/*` no `gitops-bu`
- Para cada diretório (ex: `custom-headlamp`, `shared-utils`), criar uma Application ArgoCD
- Fazer deploy no cluster `nprod-bu-x` via IP do container Docker

**Verificação:**
```bash
# Applications da BU
kubectl -n argocd get applications | grep bu-tool

# Recursos no cluster nprod
kubectl --context kind-nprod-bu-x get namespaces | grep tool
# Esperado: tool-headlamp-nprod

# Recursos no cluster prod
kubectl --context kind-prod-bu-x get namespaces | grep tool
# Esperado: tool-headlamp-prod
```

---

## Resumo — Ordem de Execução Completa

```
 Fase │ Comando                                           │ Onde
──────┼───────────────────────────────────────────────────-┼──────────────────
  1   │ kind create cluster (x3)                          │ Host local
  2   │ ./scripts/bootstrap.sh                            │ gerencia-global
  3   │ ./scripts/connect-clusters.sh                     │ gerencia-global
  4.1 │ kubectl apply -f 01-ocm-hub.yaml                  │ gerencia-global
  4.1 │ kubectl apply -f 02-ocm-klusterlet-hub.yaml       │ gerencia-global
  4.2 │ kubectl apply -f coredns-patches (x2)             │ nprod + prod
  4.3 │ kubectl apply -f 03/04-ocm-klusterlet-*.yaml      │ gerencia-global
  4.4 │ kubectl certificate approve + clusteradm accept   │ gerencia-global
  4.5 │ kubectl apply -f ocm-governance-policy-framework  │ gerencia-global
  5   │ kubectl apply root-bootstrap-nprod/prod            │ gerencia-global
  6   │ kubectl apply root-bu-x-nprod/prod                 │ gerencia-global
```

---

## Troubleshooting

### IPs dos clusters mudaram após restart do Docker

Os IPs `172.18.0.x` são atribuídos pelo Docker bridge network e mudam após reinício.

```bash
# Verificar IPs atuais
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gerencia-global-control-plane
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nprod-bu-x-control-plane
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod-bu-x-control-plane

# Re-executar o script de conexão
./scripts/connect-clusters.sh

# Atualizar CoreDNS patches (editar IP em coredns-*.yaml) e re-aplicar
kubectl --context kind-nprod-bu-x apply -f manifests/ocm-configs/coredns-patches/coredns-nprod-bu-x.yaml
kubectl --context kind-nprod-bu-x rollout restart deploy/coredns -n kube-system
kubectl --context kind-prod-bu-x apply -f manifests/ocm-configs/coredns-patches/coredns-prod-bu-x.yaml
kubectl --context kind-prod-bu-x rollout restart deploy/coredns -n kube-system
```

### ArgoCD Application stuck em "Unknown" ou "Missing"

```bash
# Verificar se o cluster secret está correto
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster -o yaml

# Forçar re-sync
kubectl -n argocd patch application <NOME> --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

### Klusterlet não conecta ao Hub

```bash
# Verificar se o DNS funciona no cluster worker
kubectl --context kind-nprod-bu-x run dns-test --rm -it --image=busybox -- nslookup gerencia-global-control-plane

# Verificar logs do klusterlet
kubectl --context kind-nprod-bu-x logs -n open-cluster-management-agent -l app=klusterlet

# Verificar CSRs pendentes no Hub
kubectl --context kind-gerencia-global get csr | grep Pending
```

### Policies OCM não aparecem nos clusters

```bash
# Verificar se o Policy Framework está rodando
kubectl get deploy -n open-cluster-management | grep governance

# Verificar PlacementBindings
kubectl get placementbindings -A

# Verificar Placement decisions
kubectl get placementdecisions -A -o yaml
```

---

## Limpeza

```bash
# Remover todos os clusters
kind delete cluster --name gerencia-global
kind delete cluster --name nprod-bu-x
kind delete cluster --name prod-bu-x

# Remover entradas do /etc/hosts
sudo sed -i '/argocd.local/d' /etc/hosts
```

---

## Proteção da Branch `main`

Todos os 3 repositórios são protegidos via **CODEOWNERS** + **Branch Protection Rules** para que apenas `@rdgoarruda` possa fazer merge na `main`.

### O que já está configurado nos repos

Cada repositório contém `.github/CODEOWNERS` com `* @rdgoarruda` (catch-all), significando que **todo PR precisa da aprovação de `@rdgoarruda`**.

### Ativar no GitHub

A proteção real é aplicada no GitHub (Settings → Rules). Execute o script automatizado:

```bash
# Instalar GitHub CLI (se necessário)
# https://cli.github.com/
sudo apt install gh   # ou: brew install gh

# Autenticar
gh auth login

# Aplicar as regras nos 3 repos
./scripts/setup-branch-protection.sh
```

O script configura:
- **Require PR** antes de merge (sem push direto na main)
- **Require 1 approval** do CODEOWNERS (`@rdgoarruda`)
- **Dismiss stale reviews** ao push de novos commits
- **Impedir deletion** da branch main
- **Impedir force-push**
- **Require linear history** (squash/rebase)

> Se preferir configurar manualmente: **Settings → Rules → Rulesets → New ruleset** em cada repositório.

---

## Decisões Arquiteturais (ADRs)

| # | Decisão | Resumo |
|---|---|---|
| [ADR-001](docs/ADR-001-three-repo-gitops-strategy.md) | Estratégia de 3 Repositórios | Separação: infra-terraform, platform-policies (global), workloads (bu) |
| [ADR-002](docs/ADR-002-single-branch-environment-per-directory.md) | Branch Única + Overlays | `main` + diretórios por ambiente (nprod/prod) + CODEOWNERS |
| [ADR-003](docs/ADR-003-ocm-over-rhacm.md) | OCM sobre RHACM | OCM para lab (leve), API 100% compatível com RHACM em produção |
| [ADR-004](docs/ADR-004-argocd-as-delivery-tool.md) | ArgoCD como Delivery Tool | Pull-based, multi-cluster, drift detection, CNCF Graduated |

---

## Repositórios Relacionados

| Repositório | Responsabilidade |
|---|---|
| **gitops-ocm-foundation** (este) | Bootstrap do ambiente local Kind + OCM + ArgoCD |
| [**gitops-global**](https://github.com/rdgoarruda/gitops-global) | Governança OCM (policies), config do Hub, bridge para BUs |
| [**gitops-bu**](https://github.com/rdgoarruda/gitops-bu) | Ferramentas e infraestrutura por Unidade de Negócio |

---

## Requisitos de Hardware

| Recurso | Mínimo | Recomendado |
|---|---|---|
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Disco | 20 GB livres | 40 GB livres |

> Os 3 clusters Kind + ArgoCD + OCM consomem aproximadamente 4-6 GB de RAM no total.