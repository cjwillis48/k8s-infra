# k8s-infra

Infrastructure-as-code for **Homie**, a two-node K3s cluster running on Raspberry Pi 4s. Serves a Ghost blog at [blog.charliewillis.com](https://blog.charliewillis.com) via Cloudflare Tunnel with zero open inbound ports.

## Architecture

Public blog (the one path that goes through Cloudflare):

```
Internet → Cloudflare CDN → Cloudflare Tunnel → cloudflared pod → Ghost pod
```

Private services (`argocd`, `pgweb`, `longhorn`):

```
Tailnet client → external reverse proxy (TLS termination) → Traefik on K3s (HTTP) → service pod
```

- **Node 1** (192.168.6.200) — K3s control plane
- **Node 2** (192.168.6.201) — K3s worker, Ghost + storage (917GB SSD)
- **No open ports** — cloudflared dials out to Cloudflare, nothing dials in
- **Network isolated** — dedicated VLAN 6, zone-based firewall, only SSH/kubectl allowed from management network
- **No TLS or auth in this cluster, on purpose** — `argocd/pgweb/longhorn.home.charliewillis.com` are terminated by an external reverse proxy on a separate box, reached over Tailscale. The cluster itself is HTTP-only and the perimeter is intentionally out of scope for this repo. Don't reintroduce cert-manager Certificates, Traefik TLSStores, or Tailscale on the cluster.

## Stack

| Layer | Technology |
|-------|-----------|
| OS | Ubuntu 24.04 LTS (ARM64) |
| K8s | K3s v1.31.4 |
| GitOps | Argo CD (app-of-apps auto-sync, internal-only access) |
| Blog | Ghost 5.x (SQLite) |
| TLS | Terminated upstream (Cloudflare for the blog, an external reverse proxy for private services). The cluster itself only speaks HTTP. |
| Ingress | Traefik + MetalLB; HTTP-only |
| External Ingress | Cloudflare Tunnel (QUIC/7844, outbound only) — blog only |
| Block Storage | Longhorn (single-replica today, S3 backups to Cloudflare R2) |
| K8s Secrets | Bitnami Sealed Secrets (SealedSecret CRD, synced by ArgoCD) |
| Ansible Secrets | SOPS + age encryption (provisioning only) |
| Backups | Daily Ghost backup to Cloudflare R2 (CronJob, 30-day retention); Longhorn volume backups to R2 |
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
│   ├── argocd/             # Argo CD install + ingress + namespace
│   │   ├── apps/           # Application CRDs for platform components (+ the `tenants` app)
│   │   ├── projects/       # AppProject CRDs (platform, locked-down default)
│   │   └── network-policies.yml
│   ├── cert-manager/       # ClusterIssuer + sealed Cloudflare API token (currently unused — kept for future certs)
│   ├── cloudflared/        # Deployment + sealed tunnel token, namespace
│   ├── ghost/              # (stub — blog manifests live in cjwillis48/blog repo)
│   ├── logging/            # Vector DaemonSet + sealed Axiom config, namespace
│   ├── longhorn/           # Longhorn ingress, storageclass, sealed S3 backup creds
│   ├── metallb/            # IP pool + L2 advertisement + network policies
│   ├── network-policies/   # Cluster-wide default-deny + shared allow rules
│   ├── pgweb/              # PGWeb deployment, ingress, network policies, namespace
│   ├── sealed-secrets/     # Sealed Secrets controller (kustomize remote base) + pub cert
│   ├── tenants/            # Helm chart: one values entry per workload repo → AppProject + Application
│   └── traefik/            # Network policies for the Traefik namespace
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
# https://argocd.home.charliewillis.com

# Verify
make status
make status-argocd
make status-logging
```

## Secrets

### K8s Secrets — Sealed Secrets

K8s secrets are managed via [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). SealedSecret resources are safe to commit to git — they can only be decrypted by the controller running in the cluster.

The controller's public cert is stored at `k8s/sealed-secrets/sealed-secrets-pub.pem` for offline sealing. Only commit the sealed output — ArgoCD syncs it to the cluster.

#### Preferred workflow: `mcp-sealed-secrets` MCP server

Day-to-day, sealed secrets are managed through the project's `mcp-sealed-secrets` MCP server, which exposes three tools to Claude Code:

- `list_sealed_secrets` — enumerate existing sealed secrets in the repo
- `seal_secret` — seal a new plaintext secret (no temp files needed)
- `edit_sealed_secret` — decrypt, edit in place, and re-seal an existing `*.sealed.yml` without ever writing plaintext to disk

Just ask Claude to "edit the axiom credentials sealed secret" or "seal a new secret for `<app>`" and it'll call the right tool.

#### Manual fallback: `make seal-secret`

If you're working without the MCP server (e.g. on a fresh machine), seal secrets the old-fashioned way:

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

Argo CD runs in the `argocd` namespace and manages all workloads via the app-of-apps pattern. The parent `argocd` Application auto-syncs from git. All child Applications also auto-sync with self-heal and prune. Platform Application manifests live in `k8s/argocd/apps/` and the `platform` AppProject in `k8s/argocd/projects/`. Workload repos (blog, ragr, …) are registered in `k8s/tenants/values.yaml`: the `tenants` Application renders a scoped AppProject + Application per entry, so onboarding a repo never touches `k8s/argocd/`. Every git source is public and fetched over HTTPS — Argo CD holds no repo credentials.

- **Access**: `https://argocd.home.charliewillis.com` (Tailnet required; TLS terminated by the upstream reverse proxy)
- **Network isolation**: `argocd` namespace has default-deny ingress plus explicit allow rules for Traefik and internal component traffic.

Apps currently managed by ArgoCD:

| App | Source | Notes |
|-----|--------|-------|
| `argocd` | this repo (`k8s/argocd`) | Self-managed, app-of-apps root |
| `sealed-secrets` | this repo (`k8s/sealed-secrets`) | Controller for `SealedSecret` CRDs |
| `cert-manager` | Helm chart + this repo | Installed but currently unused — kept for future certs |
| `traefik` | this repo (`k8s/traefik`) | HTTP ingress (TLS lives upstream) |
| `metallb` | Helm chart + this repo | LoadBalancer IP pool for Traefik |
| `cloudflared` | this repo (`k8s/cloudflared`) | Cloudflare Tunnel — fronts the public blog only |
| `longhorn` | Helm chart + this repo | Block storage + R2 backups |
| `logging` | this repo (`k8s/logging`) | Vector → Axiom |
| `pgweb` | this repo (`k8s/pgweb`) | Web UI for ad-hoc Postgres access |
| `node-exporter` | Helm chart + this repo | Host metrics, scraped by Prometheus on Proxmox |
| `kube-state-metrics` | Helm chart | Cluster object metrics on MetalLB `192.168.6.241` |
| `otel-collector` | Helm chart | Node-local OTLP collector → Tempo on Proxmox |
| `tenants` | this repo (`k8s/tenants`) | Helm chart rendering one AppProject + Application per workload repo |
| `blog` | external (`cjwillis48/blog`), via `tenants` | Ghost manifests in their own repo |
| `ragr` | external (`cjwillis48/ragr`), via `tenants` | RAG service in its own repo |

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

In **k8s-infra** (this repo) — one entry in `k8s/tenants/values.yaml`. Fastest path: in Claude Code run
`/add-homie-project <repo>` — it preflights the repo (public, `k8s/` renders, one matching `Namespace`, no
cluster-scoped kinds, kinds vs. the baseline whitelist), adds the entry, and runs the gate below. By hand:

```yaml
tenants:
  <app>:
    repoURL: https://github.com/cjwillis48/<app>.git   # public → HTTPS, no credential needed
    # namespace: <ns>          # defaults to <app>
    # targetRevision: <branch> # defaults to main — flip here to track a branch
    # path: <dir>              # defaults to k8s
    # extraKinds: [{group: apps, kind: DaemonSet}]   # beyond the team-app baseline
```

1. Add the entry, then `make tenants-diff` — the only acceptable hunks on an existing tenant are additive whitelist entries; any change under an `Application`'s `spec` means stop
2. Commit and push. The `tenants` Application renders an AppProject (that repo → that namespace, `Namespace` is the only cluster-scoped kind allowed) and an auto-syncing Application with `selfHeal` + `prune`
3. Removing the entry deletes the Application/AppProject **without** cascading to workloads (no resources finalizer); tear the namespace down by hand if you really mean it

In **the app repo**:

4. Include a `Namespace` resource with Pod Security Standards labels (`restricted` unless you need `privileged`)
5. Include a `NetworkPolicy` with default-deny ingress + explicit allow rules for expected traffic
6. Include all workload manifests (Deployment, Service, Sealed Secrets, etc.) under a `k8s/` directory
7. If the app needs to be reachable, include an HTTP-only Ingress for `<app>.home.charliewillis.com`. TLS lives upstream — for private/Tailnet-only services, add a proxy entry to the upstream reverse proxy targeting the cluster's MetalLB IP; for public services, add the host to the Cloudflare Tunnel config so cloudflared routes to Traefik.

#### Platform-managed app in this repo (e.g. PGWeb)

1. Create `k8s/<app>/` with namespace, deployment, service, ingress, network policies, and kustomization
2. Add `k8s/argocd/apps/<app>.yml` — Application CRD
3. Add the app's namespace to `k8s/argocd/projects/platform.yml` `destinations`
4. Add the app reference to `k8s/argocd/kustomization.yaml`

## Backups

Ghost content (SQLite DB + images/themes) is backed up daily at 3am to Cloudflare R2 via a Kubernetes CronJob. Each backup is stored as a timestamped directory in the `ghost-backups` R2 bucket. Backups older than 30 days are automatically pruned.

Longhorn volumes are backed up to a separate R2 bucket (`k8s-longhorn-backups`) using credentials from the `longhorn-backup-creds` sealed secret. Schedule and retention are configured in the Longhorn UI at `https://longhorn.home.charliewillis.com`.

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
