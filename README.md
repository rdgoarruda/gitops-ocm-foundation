# gitops-ocm-foundation

Repositório de **fundação e bootstrap** para replicar o ambiente multi-cluster local com Kind, ArgoCD e Open Cluster Management (OCM). Este ambiente permite testar os repositórios [`gitops-global`](https://github.com/rdgoarruda/gitops-global) (governança/políticas) e [`gitops-bu`](https://github.com/rdgoarruda/gitops-bu) (ferramentas de BU) em um lab local.

---

## Visão Geral da Arquitetura

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        REPOSITÓRIOS GIT                                │
│                                                                         │
│  gitops-ocm-foundation    gitops-global          gitops-bu-a / bu-b     │
│  (este repo)              (políticas OCM)        (tools da BU)          │
│  └─ bootstrap do lab      └─ governance/*        └─ ho/tools/*          │
│                            └─ config/*            └─ pr/tools/*         │
│                            └─ domains/bu-a/*                            │
│                            └─ domains/bu-b/*                            │
└─────────────┬──────────────────────┬────────────────────┬───────────────┘
              │                      │                    │
   ┌──────────┴──────────────────────┴────────────────────┴────────────┐
   │                                                                    │
   │  ┌─── AMBIENTE HO (Homologação) ────────────────────────────────┐  │
   │  │                                                                │  │
   │  │  gerencia-ho (Hub HO)                                         │  │
   │  │  ├── ArgoCD         → argocd-ho.local (:80)                   │  │
   │  │  ├── OCM Hub        → distribui políticas (HO)                │  │
   │  │  └── OCM Klusterlet → auto-registrado como worker             │  │
   │  │                                                                │  │
   │  │  bu-a-ho (Worker)           bu-b-ho (Worker)                  │  │
   │  │  ├── env=ho, bu=bu-a        ├── env=ho, bu=bu-b               │  │
   │  │  └── OCM Klusterlet         └── OCM Klusterlet                │  │
   │  └────────────────────────────────────────────────────────────────┘  │
   │                                                                    │
   │  ┌─── AMBIENTE PR (Produção) ───────────────────────────────────┐  │
   │  │                                                                │  │
   │  │  gerencia-pr (Hub PR)                                         │  │
   │  │  ├── ArgoCD         → argocd-pr.local (:8080)                 │  │
   │  │  ├── OCM Hub        → distribui políticas (PR)                │  │
   │  │  └── OCM Klusterlet → auto-registrado como worker             │  │
   │  │                                                                │  │
   │  │  bu-a-pr (Worker)           bu-b-pr (Worker)                  │  │
   │  │  ├── env=pr, bu=bu-a        ├── env=pr, bu=bu-b               │  │
   │  │  └── OCM Klusterlet         └── OCM Klusterlet                │  │
   │  └────────────────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────────────────┘
```

---

## Estrutura do Repositório

```
gitops-ocm-foundation/
├── scripts/
│   ├── create-clusters.sh        # Cria os 6 clusters Kind
│   ├── bootstrap.sh              # Instala HAProxy + ArgoCD (--env ho|pr)
│   ├── connect-clusters.sh       # Registra clusters BU no ArgoCD (--env ho|pr)
│   ├── fix-ips.sh                # Atualiza IPs após reboot (--only ho|pr)
│   ├── install_docker.sh         # Instala Docker no Ubuntu/Debian
│   └── k8s_env.sh               # Exporta PATH com binários locais
├── manifests/
│   ├── headlamp.yaml             # Dashboard Kubernetes (opcional)
│   ├── kind-configs/
│   │   ├── kind-gerencia-ho.yaml # Config Kind — Hub HO (portas 80/443)
│   │   ├── kind-gerencia-pr.yaml # Config Kind — Hub PR (portas 8080/8443)
│   │   ├── kind-bu-a-ho.yaml    # Config Kind — Worker BU-A HO
│   │   ├── kind-bu-a-pr.yaml    # Config Kind — Worker BU-A PR
│   │   ├── kind-bu-b-ho.yaml    # Config Kind — Worker BU-B HO
│   │   ├── kind-bu-b-pr.yaml    # Config Kind — Worker BU-B PR
│   │   └── expose-tool.yaml      # Template para expor novas ferramentas
│   └── ocm-configs/
│       ├── argocd-apps/
│       │   ├── 01-ocm-hub.yaml                      # ArgoCD App → OCM Hub (cluster-manager)
│       │   ├── 02-ocm-klusterlet-hub.yaml            # ArgoCD App → Klusterlet no Hub
│       │   └── ocm-governance-policy-framework.yaml  # ArgoCD App → Policy Framework addon
│       └── coredns-patches/
│           ├── coredns-bu-a-ho.yaml                  # DNS fix para bu-a-ho resolver o Hub HO
│           ├── coredns-bu-a-pr.yaml                  # DNS fix para bu-a-pr resolver o Hub PR
│           ├── coredns-bu-b-ho.yaml                  # DNS fix para bu-b-ho resolver o Hub HO
│           └── coredns-bu-b-pr.yaml                  # DNS fix para bu-b-pr resolver o Hub PR
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

### Fase 1 — Criar os 6 Clusters Kind

```bash
cd gitops-ocm-foundation

# Criar todos os clusters
./scripts/create-clusters.sh

# Ou criar apenas um ambiente:
./scripts/create-clusters.sh --only ho
./scripts/create-clusters.sh --only pr
```

**Verificação:**
```bash
kind get clusters
# Esperado: bu-a-ho, bu-a-pr, bu-b-ho, bu-b-pr, gerencia-ho, gerencia-pr

kubectl config get-contexts
# Deve listar: kind-gerencia-ho, kind-gerencia-pr, kind-bu-a-ho, kind-bu-a-pr, kind-bu-b-ho, kind-bu-b-pr
```

---

### Fase 2 — Bootstrap dos Hubs

Instala automaticamente: HAProxy + ArgoCD + Headlamp + OCM Hub + Klusterlet (auto-registro) + Governance Policy Framework.

```bash
# Bootstrap HO
./scripts/bootstrap.sh --env ho

# Bootstrap PR
./scripts/bootstrap.sh --env pr
```

**Obter senhas do ArgoCD:**
```bash
# Senha HO
kubectl --context kind-gerencia-ho -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

# Senha PR
kubectl --context kind-gerencia-pr -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```

**Acesso:**
| Serviço | HO | PR |
|---|---|---|
| ArgoCD | http://argocd-ho.local | http://argocd-pr.local:8080 |
| Headlamp | http://headlamp-ho.local | http://headlamp-pr.local:8080 |

---

### Fase 3 — Conectar Clusters Worker

Instala automaticamente em cada worker: ArgoCD Secret + CoreDNS + Headlamp + OCM Klusterlet. Também aprova CSRs e aceita os clusters no OCM Hub.

```bash
# Workers HO (bu-a-ho, bu-b-ho → gerencia-ho)
./scripts/connect-clusters.sh --env ho

# Workers PR (bu-a-pr, bu-b-pr → gerencia-pr)
./scripts/connect-clusters.sh --env pr
```

**Verificação:**
```bash
# OCM clusters registrados
kubectl --context kind-gerencia-ho get managedclusters
# Esperado: in-cluster, bu-a-ho, bu-b-ho

kubectl --context kind-gerencia-pr get managedclusters
# Esperado: in-cluster, bu-a-pr, bu-b-pr

# ArgoCD cluster secrets
kubectl --context kind-gerencia-ho -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
kubectl --context kind-gerencia-pr -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
```

---

### Fase 4 — Labelar Clusters e Aplicar GitOps

Com a infra pronta, aplique labels e bootstraps do `gitops-global`:

```bash
# === Labelar clusters para Placement (cada hub) ===
for env_ctx in "kind-gerencia-ho:ho:bu-a-ho:bu-b-ho" "kind-gerencia-pr:pr:bu-a-pr:bu-b-pr"; do
  IFS=: read ctx env w1 w2 <<< "$env_ctx"
  kubectl --context "$ctx" label managedcluster "$w1" env=$env bu=bu-a --overwrite
  kubectl --context "$ctx" label managedcluster "$w2" env=$env bu=bu-b --overwrite
  kubectl --context "$ctx" apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: global
EOF
  kubectl --context "$ctx" label managedcluster "$w1" cluster.open-cluster-management.io/clusterset=global --overwrite
  kubectl --context "$ctx" label managedcluster "$w2" cluster.open-cluster-management.io/clusterset=global --overwrite
done

# === Bootstrap do gitops-global ===
kubectl --context kind-gerencia-ho apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bootstrap-ho
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

kubectl --context kind-gerencia-pr apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-bootstrap-pr
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

# === Bootstrap das BUs ===
for env in ho pr; do
  ctx="kind-gerencia-${env}"
  env_path=$( [ "$env" = "ho" ] && echo "nprod" || echo "prod" )
  for bu in bu-a bu-b; do
    kubectl --context "$ctx" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-${bu}-${env}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/rdgoarruda/gitops-global.git'
    targetRevision: main
    path: domains/${bu}/${env_path}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF
  done
done
```

---

## Resumo — Ordem de Execução Completa

```
 Fase │ Comando                                           │ O que instala
──────┼───────────────────────────────────────────────────-┼──────────────────────────────
  1   │ ./scripts/create-clusters.sh                      │ 6 clusters Kind
  2   │ ./scripts/bootstrap.sh --env ho                   │ HAProxy+ArgoCD+Headlamp+OCM Hub
  2   │ ./scripts/bootstrap.sh --env pr                   │ HAProxy+ArgoCD+Headlamp+OCM Hub
  3   │ ./scripts/connect-clusters.sh --env ho            │ CoreDNS+Headlamp+OCM Klusterlet
  3   │ ./scripts/connect-clusters.sh --env pr            │ CoreDNS+Headlamp+OCM Klusterlet
  4   │ Labels + gitops-global bootstrap                  │ Governance + BU apps
```

---

## Troubleshooting

### IPs dos clusters mudaram após restart do Docker

```bash
# Script automatizado para corrigir tudo
./scripts/fix-ips.sh

# Ou apenas um ambiente
./scripts/fix-ips.sh --only ho
./scripts/fix-ips.sh --only pr
```

### ArgoCD Application stuck em "Unknown" ou "Missing"

```bash
# Verificar se o cluster secret está correto (ajustar contexto)
kubectl --context kind-gerencia-ho -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster -o yaml

# Forçar re-sync
kubectl --context kind-gerencia-ho -n argocd patch application <NOME> --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

### Klusterlet não conecta ao Hub

```bash
# Verificar DNS no cluster worker
kubectl --context kind-bu-a-ho run dns-test --rm -it --image=busybox -- nslookup gerencia-ho-control-plane

# Verificar logs do klusterlet
kubectl --context kind-bu-a-ho logs -n open-cluster-management-agent -l app=klusterlet

# Verificar CSRs pendentes no Hub
kubectl --context kind-gerencia-ho get csr | grep Pending
```

### Policies OCM não aparecem nos clusters

```bash
# Verificar se o Policy Framework está rodando (em cada hub)
kubectl --context kind-gerencia-ho get deploy -n open-cluster-management | grep governance
kubectl --context kind-gerencia-pr get deploy -n open-cluster-management | grep governance

# Verificar PlacementBindings
kubectl --context kind-gerencia-ho get placementbindings -A
```

---

## Limpeza

```bash
# Remover todos os clusters
kind delete cluster --name gerencia-ho
kind delete cluster --name gerencia-pr
kind delete cluster --name bu-a-ho
kind delete cluster --name bu-a-pr
kind delete cluster --name bu-b-ho
kind delete cluster --name bu-b-pr

# Remover entradas do /etc/hosts
sudo sed -i '/argocd-ho.local/d' /etc/hosts
sudo sed -i '/argocd-pr.local/d' /etc/hosts
```

---

## Proteção da Branch `main`

Todos os repositórios são protegidos via **CODEOWNERS** + **Branch Protection Rules**.

```bash
# Aplicar as regras nos repos
./scripts/setup-branch-protection.sh
```

---

## Decisões Arquiteturais (ADRs)

| # | Decisão | Resumo |
|---|---|---|
| [ADR-001](docs/ADR-001-three-repo-gitops-strategy.md) | Estratégia de 3 Repositórios | Separação: infra-terraform, platform-policies (global), workloads (bu) |
| [ADR-002](docs/ADR-002-single-branch-environment-per-directory.md) | Branch Única + Overlays | `main` + diretórios por ambiente (ho/pr) + CODEOWNERS |
| [ADR-003](docs/ADR-003-ocm-over-rhacm.md) | OCM sobre RHACM | OCM para lab (leve), API 100% compatível com RHACM em produção |
| [ADR-004](docs/ADR-004-argocd-as-delivery-tool.md) | ArgoCD como Delivery Tool | Pull-based, multi-cluster, drift detection, CNCF Graduated |

---

## Repositórios Relacionados

| Repositório | Responsabilidade |
|---|---|
| **gitops-ocm-foundation** (este) | Bootstrap do ambiente local Kind + OCM + ArgoCD |
| [**gitops-global**](https://github.com/rdgoarruda/gitops-global) | Governança OCM (policies), config do Hub, bridge para BUs |
| [**gitops-bu-a**](https://github.com/rdgoarruda/gitops-bu-a) | Ferramentas e infraestrutura da BU-A |
| [**gitops-bu-b**](https://github.com/rdgoarruda/gitops-bu-b) | Ferramentas e infraestrutura da BU-B |

---

## Requisitos de Hardware

| Recurso | Mínimo | Recomendado |
|---|---|---|
| CPU | 6 cores | 8+ cores |
| RAM | 12 GB | 16 GB |
| Disco | 30 GB livres | 50 GB livres |

> Os 6 clusters Kind + ArgoCD (x2) + OCM (x2) consomem aproximadamente 8-12 GB de RAM no total.