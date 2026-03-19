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
| TLS | Let's Encrypt wildcard via cert-manager + Cloudflare DNS-01 |
| LAN Ingress | Traefik + MetalLB → `*.lan.charliewillis.com` (internal services) |
| External Ingress | Cloudflare Tunnel (QUIC/7844, outbound only) |
| K8s Secrets | Bitnami Sealed Secrets (SealedSecret CRD, synced by ArgoCD) |
| Ansible Secrets | SOPS + age encryption (provisioning only) |
| Backups | Daily Ghost backup to Cloudflare R2 (CronJob, 30-day retention) |
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
│   ├── argocd/             # Argo CD install, Application CRDs, projects, ingress, namespace
│   ├── blog/               # Ghost deployment, service, PVC, backup CronJob, namespace
│   ├── cert-manager/       # ClusterIssuer + Cloudflare API token
│   ├── cloudflared/        # Deployment + sealed tunnel token, namespace
│   ├── logging/            # Vector DaemonSet + Axiom config, namespace
│   ├── metallb/            # IP pool + L2 advertisement + network policies
│   ├── pgweb/              # PGWeb deployment, ingress, network policies, namespace
│   ├── sealed-secrets/     # Sealed Secrets controller (kustomize remote base)
│   └── traefik/            # TLS certificate, TLSStore, network policies
├── scripts/
│   ├── bootstrap.sh        # Install Mac deps (incl. kubeseal), generate age key
│   ├── fetch-kubeconfig.sh # SCP kubeconfig from node-1
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

# 5. Create Cloudflare Tunnel token (see Secrets section below)
#    Create tunnel in Cloudflare Zero Trust dashboard, then seal the token:
make seal-secret IN=/tmp/cf-token.yml OUT=k8s/cloudflared/tunnel-token.sealed.yml

# 6. Create a local (untracked) Axiom secret, then seal it — only the sealed output is committed
cat > /tmp/axiom-credentials.secret.yml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: axiom-credentials
  namespace: logging
type: Opaque
stringData:
  AXIOM_TOKEN: "your-token-here"
  AXIOM_DATASET: "your-dataset-here"
EOF
make seal-secret IN=/tmp/axiom-credentials.secret.yml OUT=k8s/logging/axiom-credentials.sealed.yml
rm /tmp/axiom-credentials.secret.yml

# 7. Bootstrap cluster (namespaces + sealed-secrets controller + ArgoCD)
make deploy

# 8. Open ArgoCD UI — all apps auto-sync from git
# https://argocd.lan.charliewillis.com

# Verify
make status
make status-argocd
make status-logging
```

## Secrets

### K8s Secrets — Sealed Secrets

K8s secrets are managed via [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). SealedSecret resources are safe to commit to git — they can only be decrypted by the controller running in the cluster.

To create or rotate any sealed secret:

```bash
# 1. Write a temporary plaintext secret (never commit this)
cat > /tmp/my-secret.yml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
type: Opaque
stringData:
  KEY: "value"
EOF

# 2. Seal it
make seal-secret IN=/tmp/my-secret.yml OUT=k8s/<app>/my-secret.sealed.yml

# 3. Clean up plaintext
rm /tmp/my-secret.yml
```

The controller's public cert is stored at `k8s/sealed-secrets/sealed-secrets-pub.pem` for offline sealing. Only commit the sealed output — ArgoCD syncs it to the cluster.

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

## Argo CD

Argo CD runs in the `argocd` namespace and manages all workloads via the app-of-apps pattern. The parent `argocd` Application auto-syncs from git. All child Applications also auto-sync with self-heal and prune. Application manifests live in `k8s/argocd/apps/`.

- **LAN access**: `https://argocd.lan.charliewillis.com` (TLS via wildcard cert)
- **Network isolation**: `argocd` namespace has default-deny ingress plus explicit allow rules for Traefik and internal component traffic.

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode && echo
```

### Onboarding a New Application

#### Infrastructure component (Helm chart)

Use multi-source Applications to combine a Helm chart with git-based config in a single app.

1. Add `k8s/argocd/apps/<component>.yml` — multi-source Application with Helm chart + git config
2. Add the Helm repo URL to `k8s/argocd/projects/platform.yml` `sourceRepos`
3. Add the target namespace to the platform project `destinations`
4. Add required resource types to the platform project whitelist
5. Add the app reference to `k8s/argocd/kustomization.yaml`
6. Use `managedNamespaceMetadata` + `CreateNamespace=true` for namespace creation with PSS labels
7. Use `ServerSideApply=true` + `SkipDryRunOnMissingResource=true` for CRD-dependent resources

#### Custom app in its own repo

In **k8s-infra** (this repo):

1. Add `k8s/argocd/projects/<app>.yml` — AppProject scoped to the app's git repo and namespace
2. Add `k8s/argocd/apps/<app>.yml` — Application CRD with `automated: {selfHeal: true, prune: true}`
3. Add both to `k8s/argocd/kustomization.yaml`

In **the app repo**:

4. Include a `Namespace` resource with Pod Security Standards labels (`restricted` unless you need `privileged`)
5. Include a `NetworkPolicy` with default-deny ingress + explicit allow rules for expected traffic
6. Include all workload manifests (Deployment, Service, Sealed Secrets, etc.) under a `k8s/` directory
7. If the app needs LAN access, include an Ingress for `<app>.lan.charliewillis.com` — TLS is automatic via the wildcard cert and Traefik TLSStore

#### Platform-managed app in this repo (e.g. PGWeb)

1. Create `k8s/<app>/` with namespace, deployment, service, ingress, network policies, and kustomization
2. Add `k8s/argocd/apps/<app>.yml` — Application CRD
3. Add the app's namespace to `k8s/argocd/projects/platform.yml` `destinations`
4. Add the app reference to `k8s/argocd/kustomization.yaml`

## Backups

Ghost content (SQLite DB + images/themes) is backed up daily at 3am to Cloudflare R2 via a Kubernetes CronJob. Each backup is stored as a timestamped directory in the `ghost-backups` R2 bucket. Backups older than 30 days are automatically pruned.

Manual backup to local machine (legacy):

```bash
make backup-blog
```

Trigger a one-off backup to R2:

```bash
kubectl create job --from=cronjob/ghost-backup ghost-backup-manual -n blog
kubectl logs -f job/ghost-backup-manual -n blog
kubectl delete job ghost-backup-manual -n blog
```

## Teardown

```bash
make reset   # Uninstalls K3s from all nodes (OS hardening remains)
```

## Related

- Blog post: [I Built a Raspberry Pi Kubernetes Cluster from Scratch](https://blog.charliewillis.com/i-built-a-raspberry-pi-kubernetes-cluster-from-scratch/)
- See `PLAN.md` for the original infrastructure design
