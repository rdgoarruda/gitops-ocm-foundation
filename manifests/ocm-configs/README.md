# OCM Configs — Open Cluster Management Setup

Esta pasta contém todos os manifests necessários para reproduzir a instalação completa do OCM
no ambiente Kind, incluindo o Hub e o registro dos clusters worker via ArgoCD.

## Estrutura

```
manifests/ocm-configs/
├── argocd-apps/
│   ├── 01-ocm-hub.yaml                  # ArgoCD App → OCM Hub (cluster-manager)
│   ├── 02-ocm-klusterlet-hub.yaml        # ArgoCD App → Klusterlet no próprio hub
│   ├── 03-ocm-klusterlet-nprod.yaml      # ArgoCD App → Klusterlet em nprod-bu-x
│   └── 04-ocm-klusterlet-prod.yaml       # ArgoCD App → Klusterlet em prod-bu-x
├── argocd-cluster-secrets/
│   ├── argocd-secret-nprod-bu-x.yaml    # Secret de cluster do ArgoCD para nprod-bu-x
│   └── argocd-secret-prod-bu-x.yaml     # Secret de cluster do ArgoCD para prod-bu-x
├── coredns-patches/
│   ├── coredns-nprod-bu-x.yaml          # CoreDNS Override para nprod resolver o Hub
│   └── coredns-prod-bu-x.yaml           # CoreDNS Override para prod resolver o Hub
└── scripts/
    └── generate_argocd_cluster_secrets.py  # Script para regenerar os Cluster Secrets
```

---

## Ordem de Aplicação

### Pré-requisitos
- Clusters Kind criados: `gerencia-global`, `nprod-bu-x`, `prod-bu-x`
- ArgoCD instalado no `gerencia-global`
- `clusteradm` disponível no PATH

---

### Passo 1 — Registrar os clusters worker no ArgoCD (Cluster Secrets)

> ⚠️ Os IPs `172.18.0.x` variam entre reinicializações do Docker. Execute o script para regenerá-los.

```bash
# Regerar com os IPs atuais
python3 scripts/generate_argocd_cluster_secrets.py

# Aplicar no hub
kubectl config use-context kind-gerencia-global
kubectl apply -f argocd-cluster-secrets/argocd-secret-nprod-bu-x.yaml
kubectl apply -f argocd-cluster-secrets/argocd-secret-prod-bu-x.yaml
```

---

### Passo 2 — Corrigir DNS nos workers

Os clusters worker precisam resolver `gerencia-global-control-plane` via IP Docker.

```bash
kubectl --context kind-nprod-bu-x apply -f coredns-patches/coredns-nprod-bu-x.yaml
kubectl --context kind-nprod-bu-x rollout restart deploy/coredns -n kube-system

kubectl --context kind-prod-bu-x apply -f coredns-patches/coredns-prod-bu-x.yaml
kubectl --context kind-prod-bu-x rollout restart deploy/coredns -n kube-system
```

> Atualize o IP `172.18.0.2` em ambos os arquivos se o Hub mudar de IP após restart do Docker.

---

### Passo 3 — Instalar OCM Hub e Klusterlets via ArgoCD

```bash
kubectl config use-context kind-gerencia-global
kubectl apply -f argocd-apps/01-ocm-hub.yaml
kubectl apply -f argocd-apps/02-ocm-klusterlet-hub.yaml
kubectl apply -f argocd-apps/03-ocm-klusterlet-nprod.yaml
kubectl apply -f argocd-apps/04-ocm-klusterlet-prod.yaml
```

---

### Passo 4 — Aprovar CSRs dos clusters worker no Hub

Quando os agentes iniciarem pela primeira vez, eles enviam um CSR para o Hub.

```bash
kubectl config use-context kind-gerencia-global

# Listar CSRs pendentes
kubectl get csr

# Aprovar os CSRs dos workers
csr_nprod=$(kubectl get csr | grep nprod-bu-x | grep Pending | awk '{print $1}')
csr_prod=$(kubectl get csr | grep prod-bu-x | grep Pending | awk '{print $1}')
kubectl certificate approve $csr_nprod $csr_prod

# Aceitar os clusters no OCM Hub
clusteradm accept --clusters nprod-bu-x,prod-bu-x
```

---

### Verificação Final

```bash
kubectl config use-context kind-gerencia-global
kubectl get managedclusters
# Esperado: HUB ACCEPTED=true, JOINED=True, AVAILABLE=True
```

---

## Notas Importantes

| Item | Detalhe |
|---|---|
| IPs efêmeros | Os IPs `172.18.0.x` são atribuídos pelo Docker bridge e podem mudar |
| TLS insecure | Os Cluster Secrets usam `insecure: true` — aceitável em ambiente Kind local |
| CSR re-approval | Após restart dos pods ou mudança de IP/DNS, novos CSRs podem ser gerados |
| Hub hostname | `gerencia-global-control-plane` é o nome do container Docker do Hub |
