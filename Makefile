.PHONY: bootstrap provision deploy deploy-argocd backup-blog reset kubeconfig tunnel status status-argocd

ANSIBLE_DIR := ansible
PLAYBOOK_DIR := $(ANSIBLE_DIR)/playbooks
INVENTORY := $(ANSIBLE_DIR)/inventory/hosts.yml

# Install Mac dependencies and generate age key
bootstrap:
	./scripts/bootstrap.sh

# Run full provisioning (OS hardening + K3s install)
provision:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/provision.yml

# Deploy all K8s manifests
deploy: kubeconfig
	kubectl apply -f k8s/namespaces/
	$(MAKE) deploy-argocd
	kubectl apply -f k8s/blog/deployment.yml
	kubectl apply -f k8s/blog/pvc.yml
	kubectl apply -f k8s/blog/service.yml
	sops -d k8s/blog/mail-secret.sops.yml | kubectl apply -f -
	kubectl apply -f k8s/cloudflared/deployment.yml
	sops -d k8s/cloudflared/secret.sops.yml | kubectl apply -f -
	kubectl apply -f k8s/network-policies/

# Deploy Argo CD platform components
deploy-argocd:
	kubectl apply -f k8s/namespaces/argocd.yml
	kubectl apply -n argocd -k k8s/argocd/

# Backup blog content and sqlite database locally
backup-blog:
	./scripts/backup-blog.sh


# Full setup: provision nodes then deploy workloads
site:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml

# Fetch kubeconfig from node-1
kubeconfig:
	./scripts/fetch-kubeconfig.sh

# Create Cloudflare tunnel interactively
tunnel:
	./scripts/setup-cf-tunnel.sh

# Tear down K3s from all nodes
reset:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/reset.yml

# Decrypt SOPS secrets for editing
decrypt-secrets:
	sops -d $(ANSIBLE_DIR)/inventory/group_vars/all.sops.yml > $(ANSIBLE_DIR)/inventory/group_vars/all.sops.dec.yml
	@echo "Decrypted to all.sops.dec.yml — edit and re-encrypt with 'make encrypt-secrets'"

# Re-encrypt SOPS secrets after editing
encrypt-secrets:
	sops -e $(ANSIBLE_DIR)/inventory/group_vars/all.sops.dec.yml > $(ANSIBLE_DIR)/inventory/group_vars/all.sops.yml
	rm -f $(ANSIBLE_DIR)/inventory/group_vars/all.sops.dec.yml
	@echo "Encrypted and cleaned up decrypted file"

# Check node status
status:
	kubectl get nodes -o wide
	@echo ""
	kubectl get pods -A

# Check Argo CD component health
status-argocd:
	kubectl get ns argocd
	kubectl -n argocd get pods
	kubectl -n argocd get svc argocd-server
