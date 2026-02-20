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
| Blog | Ghost 5.x (SQLite) |
| Ingress | Cloudflare Tunnel (QUIC/7844, outbound only) |
| Secrets | SOPS + age encryption |
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
│   ├── namespaces/         # ghost, cloudflare (restricted Pod Security Standards)
│   ├── ghost/              # Deployment, Service, PVC
│   ├── cloudflared/        # Deployment + SOPS-encrypted tunnel secret
│   └── network-policies/   # Default-deny + allow cloudflared→ghost only
├── scripts/
│   ├── bootstrap.sh        # Install Mac deps, generate age key
│   ├── fetch-kubeconfig.sh # SCP kubeconfig from node-1
│   └── setup-cf-tunnel.sh  # Create Cloudflare Tunnel interactively
├── .sops.yaml              # SOPS age encryption config
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

# 6. Deploy Ghost + cloudflared + network policies
make deploy

# Verify
make status
```

## Security

- **SSH**: key-only auth, no root login, `AllowUsers charlie`
- **Firewall**: UFW deny-all incoming; allow SSH + K8s API from management network only
- **fail2ban**: bans IPs after 3 failed SSH attempts
- **Network policies**: default-deny in all namespaces; only cloudflared can reach Ghost
- **Pod Security Standards**: `restricted` profile enforced on all namespaces
- **Secrets**: SOPS + age encrypted; never plaintext in git
- **Containers**: non-root, all capabilities dropped, seccomp RuntimeDefault

## Teardown

```bash
make reset   # Uninstalls K3s from all nodes (OS hardening remains)
```

## Related

- Blog post: [I Built a Raspberry Pi Kubernetes Cluster from Scratch](https://blog.charliewillis.com/i-built-a-raspberry-pi-kubernetes-cluster-from-scratch/)
- See `PLAN.md` for the original infrastructure design
