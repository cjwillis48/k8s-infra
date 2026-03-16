# k8s-infra

Infrastructure-as-code for **Homie**, a two-node K3s cluster running on Raspberry Pi 4s. Serves a Ghost blog at [blog.charliewillis.com](https://blog.charliewillis.com) via Cloudflare Tunnel with zero open inbound ports.

## Architecture

```
Internet → Cloudflare CDN → Cloudflare Tunnel → cloudflared pod → Ghost pod
```

- **Node 1** (192.168.6.200) — K3s control plane
- **Node 2** (192.168.6.201) — K3s worker, Ghost + storage (917GB SSD)
- **No open ports** — cloudflared dials out to Cloudflare, nothing dials in
- **Network isolated** — dedicated VLAN 6, zone-based firewall, only SSH/kubectl allowed from management network

## Stack

| Layer | Technology |
|-------|-----------|
| OS | Ubuntu 24.04 LTS (ARM64) |
| K8s | K3s v1.31.4 |
| GitOps | Argo CD (app-of-apps auto-sync, internal-only access) |
| Blog | Ghost 5.x (SQLite) |
| LAN Ingress | Traefik + MetalLB → `*.homie` (internal services) |
| External Ingress | Cloudflare Tunnel (QUIC/7844, outbound only) |
| K8s Secrets | Bitnami Sealed Secrets (SealedSecret CRD, synced by ArgoCD) |
| Ansible Secrets | SOPS + age encryption (provisioning only) |
| Log Shipping | Vector DaemonSet → Axiom dataset |
| Provisioning | Ansible |

## Repo Structure

```
k8s-infra/
├── ansible/
│   ├── inventory/          # Hosts + encrypted group vars
│   ├── playbooks/          # provision.yml, site.yml, reset.yml
│   └── roles/
│       ├── common/         # OS hardening (UFW, SSH, fail2ban, cgroups)
│       ├── k3s_server/     # Control plane install + config
│       └── k3s_agent/      # Worker node install + join
├── k8s/
│   ├── namespaces/         # blog, cloudflare, argocd (restricted Pod Security Standards)
│   ├── argocd/             # Argo CD install + Application manifests
│   │   └── apps/           # ArgoCD Application CRDs (blog, cloudflared, logging, network-policies, sealed-secrets)
│   ├── blog/               # Ghost deployment, service, PVC, sealed mail secret
│   ├── cloudflared/        # Deployment + sealed tunnel token secret
│   ├── logging/            # Vector DaemonSet config and Axiom sink
│   ├── sealed-secrets/     # Sealed Secrets controller (kustomize remote base)
│   └── network-policies/   # Default-deny + explicit allow rules
├── scripts/
│   ├── bootstrap.sh        # Install Mac deps (incl. kubeseal), generate age key
│   ├── fetch-kubeconfig.sh # SCP kubeconfig from node-1
│   ├── setup-cf-tunnel.sh  # Create Cloudflare Tunnel interactively
│   └── backup-blog.sh      # Backup blog content + sqlite db to local tarball
├── .sops.yaml              # SOPS age encryption config (Ansible secrets only)
├── Makefile                # Convenience targets
└── PLAN.md                 # Original AI-generated infrastructure plan
```

## Prerequisites

- Mac with Homebrew
- SSH key access to both Pi nodes as `charlie`
- Cloudflare account with your domain

## Usage

```bash
# 1. Install dependencies and generate age encryption key
make bootstrap

# 2. Update .sops.yaml with your age public key, then encrypt secrets
sops ansible/inventory/group_vars/all.sops.yml

# 3. Provision nodes (OS hardening + K3s install)
make provision

# 4. Fetch kubeconfig from node-1
make kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# 5. Create Cloudflare Tunnel and encrypt token
make tunnel

# 6. Set Axiom token + dataset in k8s/logging/axiom-credentials.secret.yml
# Optional hardening: seal this secret and switch k8s/logging/kustomization.yaml to the sealed file
make seal-secret IN=k8s/logging/axiom-credentials.secret.yml OUT=k8s/logging/axiom-credentials.sealed.yml

# 7. Bootstrap cluster (namespaces + sealed-secrets controller + ArgoCD)
make deploy

# 8. Open ArgoCD UI (child apps can remain manual or be app-specific)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Open https://localhost:8080, sync each app

# Verify
make status
make status-argocd
make status-logging
```

## Secrets

### K8s Secrets — Sealed Secrets

K8s secrets are managed via [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). SealedSecret resources are safe to commit to git — they can only be decrypted by the controller running in the cluster.

To seal a new secret:

```bash
# Create a regular K8s Secret YAML, then seal it
make seal-secret IN=path/to/secret.yml OUT=path/to/sealed.yml
```

The controller's public cert is stored at `k8s/sealed-secrets/sealed-secrets-pub.pem` for offline sealing.

For Axiom log shipping, the bootstrap manifest is `k8s/logging/axiom-credentials.secret.yml`.
Replace placeholder values locally, seal it with `make seal-secret`, and commit only the sealed output.

### Ansible Secrets — SOPS + age

Ansible provisioning secrets (e.g., `ansible/inventory/group_vars/all.sops.yml`) are encrypted with SOPS + age. These are used only during Ansible runs and never touch ArgoCD.

```bash
make decrypt-secrets   # Decrypt for editing
make encrypt-secrets   # Re-encrypt after editing
```

## Security

- **SSH**: key-only auth, no root login, `AllowUsers charlie`
- **Firewall**: UFW deny-all incoming; allow SSH + K8s API from management network only
- **fail2ban**: bans IPs after 3 failed SSH attempts
- **Network policies**: default-deny in all namespaces with explicit allow rules only
- **Pod Security Standards**: `restricted` profile enforced on all namespaces
- **Secrets**: Sealed Secrets for K8s (committed as encrypted CRDs); SOPS + age for Ansible
- **Containers**: non-root, all capabilities dropped, seccomp RuntimeDefault

## Argo CD (Internal-Only)

Argo CD runs in the `argocd` namespace and manages all workloads via the app-of-apps pattern. The parent `argocd` Application auto-syncs from git, while child Applications can be configured per app (manual or automated). All Application manifests live in `k8s/argocd/apps/`.

- **No public route**: Argo CD is not exposed through Cloudflare Tunnel.
- **Access path**: use `kubectl port-forward` from your trusted management VLAN machine.
- **Network isolation**: `argocd` namespace has default-deny ingress plus explicit in-namespace allow rules for component-to-component traffic.

Access Argo CD UI/API locally:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080` in your browser.

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode && echo
```

After first login, rotate the admin password and disable/delete the initial secret when no longer needed.

### Onboarding a New Application

#### Infra-only component (e.g. a new Helm chart like cert-manager)

1. Add `k8s/argocd/apps/<component>.yml` — Application CRD pointing to the Helm repo
2. Add the Helm repo URL to `k8s/argocd/projects/platform.yml` `sourceRepos`
3. Add the target namespace to the platform project `destinations`
4. Add a namespace definition in `k8s/namespaces/` if needed
5. Add the app reference to `k8s/argocd/kustomization.yaml`
6. If it needs a `*.homie` route, add an Ingress in `k8s/ingresses/`

#### Custom app in its own repo (e.g. a Flask API)

In **k8s-infra** (this repo):

1. Add `k8s/argocd/projects/<app>.yml` — AppProject scoped to the app's git repo and namespace
2. Add `k8s/argocd/apps/<app>.yml` — Application CRD pointing to the app repo's `k8s/` path
3. Add both to `k8s/argocd/kustomization.yaml`
4. Add `k8s/ingresses/<app>.yml` with the Ingress for `<app>.homie`
5. Add the ingress to `k8s/ingresses/kustomization.yaml`

In **the app repo**:

6. Maintain all workload manifests (Namespace, Deployment, Service, Sealed Secrets, NetworkPolicies) under a `k8s/` directory
7. Push — ArgoCD auto-syncs from the app repo

The app repo owns its workload; k8s-infra owns ArgoCD registration and ingress routing.

## Backups

Create a local Ghost backup tarball (content files + sqlite db):

```bash
make backup-blog
```

By default backups are written to `./backups/blog-backup-<timestamp>.tgz`.

## Teardown

```bash
make reset   # Uninstalls K3s from all nodes (OS hardening remains)
```

## Related

- Blog post: [I Built a Raspberry Pi Kubernetes Cluster from Scratch](https://blog.charliewillis.com/i-built-a-raspberry-pi-kubernetes-cluster-from-scratch/)
- See `PLAN.md` for the original infrastructure design
