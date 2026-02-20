# K8s Home Lab Infrastructure Plan

## Context
Two Raspberry Pi 4 nodes (Ubuntu 22.04.5, ARM64) on VLAN 6 (192.168.6.0/24), freshly imaged with no K8s installed. Goal: fully automated, security-first K8s cluster hosting a Ghost blog, accessible via Cloudflare Tunnel with no open ports.

## Hardware
- **Node 1:** homie-k8s-node-1, 192.168.6.200, 220GB SSD → K3s server (control plane)
- **Node 2:** homie-k8s-node-2, 192.168.6.201, 917GB SSD → K3s agent (worker, storage)

## Repo Structure
```
k8s-infra/
├── .gitignore
├── .sops.yaml                        # SOPS age encryption config
├── Makefile                          # Convenience targets
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml           # 2 Pi nodes
│   ├── group_vars/
│   │   ├── all.yml                   # Shared vars
│   │   └── all.sops.yml             # Encrypted secrets (K3s token)
│   ├── playbooks/
│   │   ├── site.yml                  # Full provision + deploy
│   │   ├── provision.yml             # OS hardening + K3s install
│   │   └── reset.yml                 # Tear down K3s
│   └── roles/
│       ├── common/                   # OS hardening
│       ├── k3s_server/               # K3s server install (node-1)
│       └── k3s_agent/                # K3s agent install (node-2)
├── k8s/
│   ├── namespaces/                   # ghost.yml, cloudflare.yml
│   ├── ghost/                        # deployment, service, pvc
│   ├── cloudflared/                  # deployment, encrypted secret
│   └── network-policies/             # default-deny, allow rules
└── scripts/
    ├── bootstrap.sh                  # Install Mac deps, generate age key
    ├── fetch-kubeconfig.sh           # Get kubeconfig from node-1
    └── setup-cf-tunnel.sh            # Create CF tunnel interactively
```

## Implementation Phases

### Phase 1: Repo Bootstrap & Secrets Setup
- Create directory structure, `.gitignore`, `.sops.yaml`
- Install Mac prerequisites: `brew install ansible sops age helm kubectl cloudflared`
- Generate age keypair for SOPS encryption
- Create Ansible inventory and encrypt K3s token
- Initial git commit

### Phase 2: Ansible Common Role (OS Hardening)
Apply to both nodes:
- apt update/upgrade
- Disable swap permanently
- Enable cgroups (`cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt`)
- Load kernel modules: `br_netfilter`, `overlay`
- Sysctl tuning (ip_forward, bridge-nf-call-iptables)
- SSH hardening (key-only auth, no root login, `AllowUsers charlie`)
- UFW firewall (deny incoming, allow SSH/6443/8472/10250 from VLAN 6 only)
- fail2ban for SSH
- Automatic security updates via unattended-upgrades

### Phase 3: K3s Cluster Installation
**Server (node-1):** K3s config at `/etc/rancher/k3s/config.yaml`:
- Disable traefik and servicelb (using Cloudflare Tunnel instead)
- TLS SAN: 192.168.6.200, homie-k8s-node-1
- Audit logging enabled
- Node label: `node-role=server`

**Agent (node-2):** Joins via server URL + shared token
- Node labels: `node-role=agent`, `storage-tier=large`

**Kubeconfig:** SCP from node-1, replace 127.0.0.1 with 192.168.6.200

### Phase 4: Cloudflare Tunnel
- Create tunnel in CF Zero Trust dashboard (remotely managed)
- Configure public hostname: `blog.charliewillis.com` → `http://ghost.ghost.svc.cluster.local:2368`
- Deploy cloudflared in-cluster with tunnel token (SOPS-encrypted)
- Outbound-only on port 7844/QUIC — no inbound ports needed

### Phase 5: Ghost Blog
- **SQLite** (not MySQL) — lightweight for Pi, no separate DB pod needed
- Single replica with `Recreate` strategy (SQLite can't handle concurrent writers)
- PVC via K3s local-path-provisioner (5Gi)
- `nodeSelector: storage-tier: large` → schedules on node-2 (917GB SSD)
- Resource limits: 256Mi request / 512Mi limit
- ClusterIP service only (cloudflared connects internally)

### Phase 6: Network Policies & Hardening
- Default-deny ingress in ghost and cloudflare namespaces
- Allow cloudflared → ghost:2368 only
- Pod Security Standards (`restricted` profile on namespaces)
- `automountServiceAccountToken: false` on all workload pods
- Image pinning (no `latest` tags)

## Key Design Decisions
| Decision | Why |
|----------|-----|
| Plain manifests over Helm for Ghost | Bitnami chart forces MariaDB; SQLite is lighter for Pi |
| Remotely-managed CF Tunnel | Ingress rules in CF dashboard, no config files in-cluster |
| SOPS + age over sealed-secrets | Works for both Ansible and K8s secrets, no in-cluster controller |
| K3s config file over CLI flags | Persists across restarts, avoids systemd flag issues |
| Ghost pinned to node-2 | 917GB SSD for content storage |

## Traffic Flow
```
Internet → Cloudflare CDN (blog.charliewillis.com)
         → Cloudflare Tunnel
         → cloudflared pod (outbound connection from cluster)
         → ghost.ghost.svc.cluster.local:2368
         → Ghost pod
```

## Verification
1. `ansible-playbook provision.yml` completes without errors
2. `kubectl get nodes` shows both nodes Ready
3. `kubectl get pods -A` shows ghost + cloudflared running, no traefik/servicelb
4. `curl https://blog.charliewillis.com` returns Ghost setup page
5. Password SSH to nodes is rejected (key-only)
6. `kubectl port-forward` to ghost works locally
