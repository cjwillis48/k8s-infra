.PHONY: bootstrap provision deploy deploy-argocd backup-blog reset kubeconfig status status-argocd status-logging seal-secret

ANSIBLE_DIR := ansible
PLAYBOOK_DIR := $(ANSIBLE_DIR)/playbooks
INVENTORY := $(ANSIBLE_DIR)/inventory/hosts.yml

# Install Mac dependencies and generate age key
bootstrap:
	./scripts/bootstrap.sh

# Run full provisioning (OS hardening + K3s install)
provision:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/provision.yml

# Bootstrap cluster: ArgoCD + sealed-secrets (all other namespaces managed by ArgoCD)
deploy: kubeconfig
	kubectl apply -f k8s/namespaces/argocd.yml
	kubectl apply -k k8s/sealed-secrets/
	$(MAKE) deploy-argocd

# Deploy Argo CD platform components
deploy-argocd:
	kubectl apply -f k8s/namespaces/argocd.yml
	kubectl apply -n argocd -k k8s/argocd/

# Seal a K8s secret using the controller's public cert
# Usage: make seal-secret IN=path/to/secret.yml OUT=path/to/sealed.yml
seal-secret:
	kubeseal --format yaml \
		--cert k8s/sealed-secrets/sealed-secrets-pub.pem \
		< $(IN) > $(OUT)

# Backup blog content and sqlite database locally
backup-blog:
	./scripts/backup-blog.sh


# Full setup: provision nodes then deploy workloads
site:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml

# Fetch kubeconfig from node-1
kubeconfig:
	./scripts/fetch-kubeconfig.sh


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
	kubectl -n argocd get applications

# Check logging pipeline health
status-logging:
	kubectl get ns logging
	kubectl -n logging get daemonset vector-agent
	kubectl -n logging get pods -l app=vector-agent
