# Platform Policies

This directory manages **Infrastructure Workloads and Configurations** via Open Cluster Management (OCM).
In our GitOps workflow, these policies enforce platform-wide standard configurations (e.g., standard namespaces, RBAC, quotas) and security controls across our multi-cloud Kubernetes clusters (`ROSA`, `ARO`, `AKS`, `EKS`, and `OCP`).

**Note:** This strategy is strictly scoped to infrastructure workloads, not application workloads.

## Architecture

To enforce total segregation between environments, we rely on **Kustomize** rather than Helm, aligning with the team's current technical proficiency.

* **Base**: Contains the core infrastructure policies, placement bindings, and a generic multi-cloud placement rule.
* **Overlays**: Defines environment-specific (`ho` and `pr`) Kustomize overlays.

Hub clusters (`gerencia-ho` and `gerencia-pr`) sync directly from their respective overlays. The Kustomize patches inject strict environment label selectors (`environment: ho` and `environment: pr`) into the base OCM `Placement` rules.

This ensures:
1. **Total Segregation**: A policy meant for homologation (`ho`) cannot be inadvertently distributed to production (`pr`).
2. **Multi-cloud Support**: Placements are aware of standard vendor labels, correctly targeting Azure, AWS, and On-Premises environments automatically.

## Best Practices

1. **Use Overlays for Strict Environments**: Always create a distinct overlay for any new environment.
2. **Patch Placements Carefully**: The `env-patch.yaml` patches the predicates of a `Placement`. Make sure it uses a `matchExpressions` rule targeting the `environment` label properly.
3. **No Direct Base Deployments**: Never apply the base directly to a Hub cluster; always go through an overlay.
