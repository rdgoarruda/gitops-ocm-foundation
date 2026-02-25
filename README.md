# gitops-ocm-foundation

Repositório de **fundação e bootstrap** para replicar o ambiente multi-cluster local com Kind, ArgoCD e Open Cluster Management (OCM). Permite testar os repositórios [`gitops-global`](https://github.com/rdgoarruda/gitops-global) (governança/políticas) e [`gitops-bu-a`](https://github.com/rdgoarruda/gitops-bu-a) / [`gitops-bu-b`](https://github.com/rdgoarruda/gitops-bu-b) (ferramentas de BU) em um lab local Kind.

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
   │  │  ├── ArgoCD         → argocd-ho.local                         │  │
   │  │  ├── Headlamp       → headlamp-ho.local                       │  │
   │  │  ├── OCM Hub        → distribui políticas (HO)                │  │
   │  │  └── HAProxy Ingress → ingress para hub                       │  │
   │  │                                                                │  │
   │  │  bu-a-ho (Worker)           bu-b-ho (Worker)                  │  │
   │  │  ├── env=ho, bu=bu-a        ├── env=ho, bu=bu-b               │  │
   │  │  ├── HAProxy Ingress        ├── HAProxy Ingress                │  │
   │  │  ├── headlamp-bu-a-ho.local ├── headlamp-bu-b-ho.local        │  │
   │  │  └── sample-app-bu-a-ho.local └── sample-app-bu-b-ho.local   │  │
   │  └────────────────────────────────────────────────────────────────┘  │
   │                                                                    │
   │  ┌─── AMBIENTE PR (Produção) ───────────────────────────────────┐  │
   │  │  gerencia-pr → argocd-pr.local | headlamp-pr.local            │  │
   │  │  bu-a-pr → sample-app-bu-a-pr.local | headlamp-bu-a-pr.local  │  │
   │  │  bu-b-pr → sample-app-bu-b-pr.local | headlamp-bu-b-pr.local  │  │
   │  └────────────────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────────────────┘
```

---

## Estrutura do Repositório

```
gitops-ocm-foundation/
├── scripts/
│   ├── create-clusters.sh        # Cria os 6 clusters Kind
│   ├── bootstrap.sh              # Instala HAProxy + ArgoCD + OCM Hub (--env ho|pr)
│   ├── connect-clusters.sh       # Registra BUs no ArgoCD + OCM (--env ho|pr)
│   ├── fix-ips.sh                # Atualiza IPs + /etc/hosts após reboot Docker
│   ├── install_docker.sh         # Instala Docker no Ubuntu/Debian
│   └── k8s_env.sh               # Exporta PATH com binários locais
├── manifests/
│   ├── headlamp.yaml             # Dashboard Kubernetes (workers)
│   ├── kind-configs/             # Configs Kind para cada cluster (portas/mapeamentos)
│   └── ocm-configs/
│       ├── argocd-apps/          # ArgoCD Apps do OCM Hub + Policy Framework
│       └── coredns-patches/      # CoreDNS patches para workers resolverem o Hub
├── docs/                         # ADRs e guias de arquitetura
└── vault/                        # Tokens do Headlamp (gitignored)
```

---

## Pré-requisitos

| Ferramenta | Versão mínima | Finalidade |
|---|---|---|
| **Docker** | 24+ | Runtime dos containers Kind |
| **kind** | 0.20+ | Cria clusters K8s locais |
| **kubectl** | 1.28+ | CLI Kubernetes |
| **helm** | 3.12+ | Instalação de charts (HAProxy, ArgoCD) |
| **clusteradm** | 0.8+ | CLI do OCM |

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
./scripts/create-clusters.sh

# Verificação
kind get clusters
# Esperado: bu-a-ho, bu-a-pr, bu-b-ho, bu-b-pr, gerencia-ho, gerencia-pr
```

### Fase 2 — Bootstrap dos Hubs

Instala: HAProxy + ArgoCD + Headlamp + OCM Hub + Klusterlet + Governance Policy Framework.

```bash
./scripts/bootstrap.sh --env ho
./scripts/bootstrap.sh --env pr
```

**Senhas do ArgoCD:**
```bash
kubectl --context kind-gerencia-ho -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Fase 3 — Conectar Clusters Worker

```bash
./scripts/connect-clusters.sh --env ho
./scripts/connect-clusters.sh --env pr
```

> ⚠️ **Sobre `connect-clusters.sh`:** O script extrai os certificados TLS usando jsonpath com filtro explícito pelo nome do contexto (`?(@.name==...)`) para garantir que cada cluster receba seu próprio CA — não o índice `[0]` genérico do kubeconfig, que causaria que todos os workers recebessem o certificado do primeiro cluster.

### Fase 4 — Bootstrap GitOps (gitops-global)

```bash
# HO
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
    path: bootstrap/ho
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
EOF

# PR (análogo com path: bootstrap/pr e context kind-gerencia-pr)
```

---

## DNS Local — Todos os Clusters

Os nomes `.local` são mapeados via `/etc/hosts` para os IPs dos containers Docker:

| Cluster | Hostnames |
|---|---|
| `gerencia-ho` | `argocd-ho.local`, `headlamp-ho.local` |
| `gerencia-pr` | `argocd-pr.local`, `headlamp-pr.local` |
| `bu-a-ho` | `sample-app-bu-a-ho.local`, `headlamp-bu-a-ho.local` |
| `bu-a-pr` | `sample-app-bu-a-pr.local`, `headlamp-bu-a-pr.local` |
| `bu-b-ho` | `sample-app-bu-b-ho.local`, `headlamp-bu-b-ho.local` |
| `bu-b-pr` | `sample-app-bu-b-pr.local`, `headlamp-bu-b-pr.local` |

Após um reboot do Docker (os IPs dos containers mudam!):

```bash
# Atualiza todos os IPs no /etc/hosts e nos cluster secrets do ArgoCD
./scripts/fix-ips.sh

# Ou apenas um ambiente
./scripts/fix-ips.sh --only ho
```

---

## Decisão Arquitetural: Push Model sem argocd-pull-integration

> 📖 Referência: [open-cluster-management-io/argocd-pull-integration](https://github.com/open-cluster-management-io/argocd-pull-integration)

O `argocd-pull-integration` é um controller OCM que habilita o **Pull Model** do ArgoCD: em vez de o hub empurrar recursos para os clusters, cada cluster puxa suas próprias configurações de forma autônoma. É a abordagem correta para ambientes com restrições de rede (sem acesso direto do hub para os workers).

**Por que não usamos aqui:**

No nosso ambiente, adotamos o **Push Model** padrão do ArgoCD (hub conecta diretamente via TLS nos workers). A integração com OCM `PlacementDecision` é feita apenas através do **`clusterDecisionResource` generator** do ApplicationSet — sem precisar do controller `argocd-pull-integration`.

O problema prático encontrado é que, ao instalar o `argocd-pull-integration` no mesmo cluster ArgoCD (modo `--mode=basic`), ele cria automaticamente ArgoCD cluster secrets para cada `ManagedCluster`, mas usa os hostnames internos Docker (`bu-a-ho-control-plane`) sem injetar os certificados TLS corretos — sabotando os secrets válidos gerados pelo `connect-clusters.sh`:

```
# O que o argocd-pull-integration criava (INVÁLIDO):
bu-a-ho-secret → https://bu-a-ho-control-plane:6443  (sem caData/certData)

# O que o connect-clusters.sh cria (VÁLIDO):
bu-a-ho-secret → https://172.18.0.3:6443  (com TLS correto)
```

**Solução adotada:** `argocd-pull-integration` não instalado. O `clusterDecisionResource` generator acessa os `PlacementDecision` resources diretamente via API OCM no hub, e o ArgoCD usa os cluster secrets TLS gerados pelo `connect-clusters.sh`.

---

## Troubleshooting

### IPs mudaram após restart do Docker
```bash
./scripts/fix-ips.sh
```

### ArgoCD: "2 clusters with the same name"
Causado por cluster secrets duplicados (um criado manualmente, outro por um controller automático). Solução:
```bash
# Listar e remover secrets duplicados
kubectl --context kind-gerencia-ho -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
kubectl --context kind-gerencia-ho -n argocd delete secret <nome-do-duplicado>

# Re-executar connect-clusters.sh para recriar corretamente
./scripts/connect-clusters.sh --env ho
```

### ApplicationSet com erro "x509: certificate signed by unknown authority"
Indica que o cluster secret tem o CA errado (provavelmente do cluster `bu-a` sendo usado para `bu-b`). Solução:
```bash
# Recriar os secrets com o script corrigido
kubectl --context kind-gerencia-ho -n argocd delete secret bu-a-ho-secret bu-b-ho-secret
./scripts/connect-clusters.sh --env ho
kubectl --context kind-gerencia-ho delete pod -n argocd -l app.kubernetes.io/name=argocd-server
```

### Klusterlet não conecta ao Hub
```bash
kubectl --context kind-bu-a-ho run dns-test --rm -it --image=busybox -- \
  nslookup gerencia-ho-control-plane
kubectl --context kind-bu-a-ho logs -n open-cluster-management-agent -l app=klusterlet
```

---

## Limpeza

```bash
kind delete cluster --name gerencia-ho gerencia-pr bu-a-ho bu-a-pr bu-b-ho bu-b-pr

# Remover entradas do /etc/hosts
sudo sed -i '/\.local$/d' /etc/hosts
```

---

## Repositórios Relacionados

| Repositório | Responsabilidade |
|---|---|
| **gitops-ocm-foundation** (este) | Bootstrap do ambiente Kind + OCM + ArgoCD + DNS local |
| [**gitops-global**](https://github.com/rdgoarruda/gitops-global) | Governança OCM, config Hub, ApplicationSets por BU |
| [**gitops-bu-a**](https://github.com/rdgoarruda/gitops-bu-a) | Ferramentas e workloads da BU-A |
| [**gitops-bu-b**](https://github.com/rdgoarruda/gitops-bu-b) | Ferramentas e workloads da BU-B |

---

## Decisões Arquiteturais (ADRs)

| # | Decisão | Resumo |
|---|---|---|
| [ADR-001](docs/ADR-001-three-repo-gitops-strategy.md) | 3 Repositórios GitOps | foundation + global (policies) + bu (workloads) |
| [ADR-002](docs/ADR-002-single-branch-environment-per-directory.md) | Branch Única + Overlays | `main` + diretórios `ho/pr` + CODEOWNERS |
| [ADR-003](docs/ADR-003-ocm-over-rhacm.md) | OCM sobre RHACM | OCM leve para lab, API compatível com RHACM |
| [ADR-004](docs/ADR-004-argocd-as-delivery-tool.md) | ArgoCD como Delivery | Push model, drift detection, CNCF Graduated |

---

## Requisitos de Hardware

| Recurso | Mínimo | Recomendado |
|---|---|---|
| CPU | 6 cores | 8+ cores |
| RAM | 12 GB | 16 GB |
| Disco | 30 GB livres | 50 GB livres |

> Os 6 clusters Kind + ArgoCD (×2) + OCM (×2) consomem aproximadamente 8–12 GB de RAM no total.