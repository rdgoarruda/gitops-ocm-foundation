# OCM Configs para Ambiente Multi-Cluster (6 clusters)

Configurações do Open Cluster Management (OCM) para o ambiente local com Kind.

## Estrutura

```
ocm-configs/
├── argocd-apps/
│   ├── 01-ocm-hub.yaml                      # ArgoCD App → OCM Hub (cluster-manager)
│   ├── 02-ocm-klusterlet-hub.yaml            # ArgoCD App → Klusterlet no Hub
│   └── ocm-governance-policy-framework.yaml  # ArgoCD App → Policy Framework addon
└── coredns-patches/
    ├── coredns-bu-a-ho.yaml                  # CoreDNS → bu-a-ho resolver gerencia-ho
    ├── coredns-bu-a-pr.yaml                  # CoreDNS → bu-a-pr resolver gerencia-pr
    ├── coredns-bu-b-ho.yaml                  # CoreDNS → bu-b-ho resolver gerencia-ho
    └── coredns-bu-b-pr.yaml                  # CoreDNS → bu-b-pr resolver gerencia-pr
```

## Pré-requisitos

- 6 clusters Kind criados: `gerencia-ho`, `gerencia-pr`, `bu-a-ho`, `bu-a-pr`, `bu-b-ho`, `bu-b-pr`
- ArgoCD instalado nos hubs (`gerencia-ho` e `gerencia-pr`)
- Clusters BU registrados no ArgoCD de cada hub

## Ordem de Aplicação (por hub)

Repita para cada hub (HO e PR), ajustando o contexto:

```bash
# 1. OCM Hub + Klusterlet do Hub
kubectl --context kind-gerencia-ho apply -f argocd-apps/01-ocm-hub.yaml
kubectl --context kind-gerencia-ho apply -f argocd-apps/02-ocm-klusterlet-hub.yaml

# 2. CoreDNS patches nos workers (para resolver hostname do hub)
kubectl --context kind-bu-a-ho apply -f coredns-patches/coredns-bu-a-ho.yaml
kubectl --context kind-bu-a-ho rollout restart deploy/coredns -n kube-system
kubectl --context kind-bu-b-ho apply -f coredns-patches/coredns-bu-b-ho.yaml
kubectl --context kind-bu-b-ho rollout restart deploy/coredns -n kube-system

# 3. Aprovar clusters
kubectl --context kind-gerencia-ho get csr -w
kubectl --context kind-gerencia-ho certificate approve <CSR_NAMES>
clusteradm accept --clusters bu-a-ho,bu-b-ho

# 4. Policy Framework
kubectl --context kind-gerencia-ho apply -f argocd-apps/ocm-governance-policy-framework.yaml
```

## Notas

| Item | Detalhe |
|---|---|
| Hub hostnames | `gerencia-ho-control-plane` e `gerencia-pr-control-plane` (nomes dos containers Docker) |
| CoreDNS patches | Necessários porque os workers precisam resolver o hostname Docker do hub via IP |
| IPs mudam | Após reinício do Docker, rode `./scripts/fix-ips.sh` para atualizar tudo |
