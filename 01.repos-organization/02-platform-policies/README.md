# Platform Policies

This directory manages the Open Cluster Management (OCM) infrastructure policies for the platform. It follows a pure Kustomize GitOps approach to distribute and enforce policies across a multi-cluster, multi-cloud environment, while ensuring strict segregation between environments (Homologation and Production).

## Architecture

We use **Kustomize** to manage configurations, as it provides a clean and understandable way to share common policies and apply environment-specific overlays without the complexity of Helm charts.

### Directory Structure

```
02-platform-policies/
├── base/
│   ├── kustomization.yaml
│   └── policy-infra-baseline.yaml  # Base policy definitions (shared)
└── overlays/
    ├── ho/                         # Homologation Environment Overlay
    │   ├── kustomization.yaml      # Patches and includes base + ho specific resources
    │   ├── placement-ho.yaml       # Placement targeting env=ho clusters
    │   └── placementbinding-ho.yaml
    └── pr/                         # Production Environment Overlay
        ├── kustomization.yaml      # Patches and includes base + pr specific resources
        ├── placement-pr.yaml       # Placement targeting env=pr clusters
        └── placementbinding-pr.yaml
```

## Environment Segregation and Targeting

The policies are distributed but completely segregated by environment using OCM `Placement` rules.

*   **`ho` (Homologation):** The `overlays/ho/placement-ho.yaml` targets clusters that have the label `env=ho`.
*   **`pr` (Production):** The `overlays/pr/placement-pr.yaml` targets clusters that have the label `env=pr`.

Furthermore, both environments target multiple Kubernetes distributions across different clouds by matching the `vendor` label against:
*   `ROSA` (Red Hat OpenShift Service on AWS)
*   `ARO` (Azure Red Hat OpenShift)
*   `AKS` (Azure Kubernetes Service)
*   `EKS` (Amazon Elastic Kubernetes Service)
*   `OCP` (On-Premises OpenShift Container Platform)

## How to Add a New Policy

1.  **Create the Base Policy:** Add your new OCM `Policy` definition (e.g., `my-new-policy.yaml`) to the `base/` directory. Ensure it is agnostic of any specific environment.
2.  **Update Base Kustomization:** Add `my-new-policy.yaml` to the `resources` list in `base/kustomization.yaml`.
3.  **Update Overlays:**
    *   If the policy applies to **both** environments, add a `Patch` in both `overlays/ho/kustomization.yaml` and `overlays/pr/kustomization.yaml` to rename it appropriately (e.g., to `my-new-policy-ho` and `my-new-policy-pr`).
    *   Update the `subjects` list in the respective `PlacementBinding` files (`placementbinding-ho.yaml` and `placementbinding-pr.yaml`) to link the patched policy name to the environment's `Placement`.

## How to Test Policies Locally

You can render the policies locally using `kubectl` to verify the generated manifests before pushing changes:

```bash
# Render Homologation policies
kubectl kustomize overlays/ho/

# Render Production policies
kubectl kustomize overlays/pr/
```
