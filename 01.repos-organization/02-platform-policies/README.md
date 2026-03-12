# Platform Policies via Open Cluster Management (OCM)

This directory contains Open Cluster Management (OCM) policies configured via Kustomize to manage **Infrastructure Workloads and Configs** across a multi-cluster, multi-cloud environment.

> ⚠️ **IMPORTANT**: This structure is explicitly designed for **INFRASTRUCTURE WORKLOADS AND CONFIGS ONLY**. Do not use it for Application Workloads. Application delivery should be handled by a separate process tailored for apps (e.g. ArgoCD AppOfApps directly without OCM policies, or separate repos).

## Architecture & Best Practices

To simplify policy distribution without relying on Helm charts, this setup heavily utilizes **Kustomize** to distribute generic policies across diverse Kubernetes distributions (e.g., **ROSA, ARO, AKS, EKS, OCP**) while ensuring strict environment segregation (**ho** for homologation, **pr** for production).

### Kustomize Directory Structure

```
02-platform-policies/
├── base/
│   ├── kustomization.yaml
│   ├── placement/
│   │   └── placement.yaml     # Generic PlacementRule targeting multiple vendors
│   └── policies/
│       └── policy-namespace.yaml  # Sample Policy
└── overlays/
    ├── ho/
    │   ├── kustomization.yaml     # Adds '-ho' suffix
    │   └── patch-placement.yaml   # Targets clusters labeled with `env: ho`
    └── pr/
        ├── kustomization.yaml     # Adds '-pr' suffix
        └── patch-placement.yaml   # Targets clusters labeled with `env: pr`
```

### 1. Environment Segregation

We enforce environment segregation using Kustomize overlays. The base configuration contains the core policy definitions, while the `ho` and `pr` overlays patch the `PlacementRule` to target specific clusters based on their labels.

- `overlays/ho/patch-placement.yaml` selects clusters with `env: ho`.
- `overlays/pr/patch-placement.yaml` selects clusters with `env: pr`.

The overlays also add a unique suffix (e.g., `-ho` or `-pr`) to all resource names. This prevents collisions when policies are synced to an OCM Hub cluster that manages both environments, allowing a single Hub to clearly separate policies per environment scope.

### 2. Multi-Cloud Targeting

The base `PlacementRule` natively targets various cloud providers' Kubernetes offerings via standard cluster labels. For example:

```yaml
spec:
  clusterSelector:
    matchExpressions:
      - key: vendor
        operator: In
        values:
          - rosa
          - aro
          - aks
          - eks
          - ocp
```

This setup ensures that policies only affect compatible multicloud Kubernetes distributions that the team officially supports.

## Usage

To preview the manifests for a specific environment:

```bash
# Preview Homologation (ho) policies
kubectl kustomize overlays/ho

# Preview Production (pr) policies
kubectl kustomize overlays/pr
```

These overlays should be synced by a GitOps agent (e.g., ArgoCD) operating inside the OCM Hub cluster, pointed directly to the respective `overlays/ho` or `overlays/pr` paths.
