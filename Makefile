# .DEFAULT_GOAL := create
.DEFAULT_GOAL := up

create:
	@kind create cluster --config cluster/config.yaml

destroy:
	@kind delete clusters kind

pre:
	# @helm plugin install https://github.com/databus23/helm-diff
	# ref:
	# https://kind.sigs.k8s.io/docs/user/loadbalancer/#installing-metallb-using-default-manifests
	@kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
	@kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=120s
	@kubectl apply -f manifests/
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	@helm repo update
	@helm search repo ingress-nginx
	@helm upgrade --install \
			--namespace ingress-nginx \
			--create-namespace \
			-f values/ingress-nginx/values.yaml \
			ingress-nginx ingress-nginx/ingress-nginx

helm:
	@helmfile apply

up: create pre helm

reset: destroy create pre helm

passwd:
	@echo "JENKINS"
	@kubectl get secret -n jenkins jenkins -ojson | jq -r '.data."jenkins-admin-password"' | base64 -d
	@echo "ArgoCD"
	# @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
	@kubectl get secret -n argocd argocd-initial-admin-secret -ojson | jq -r '.data.password' | base64 -d
	@echo "GITLAB"
	@kubectl get secret <name>-gitlab-initial-root-password -ojsonpath='{.data.password}' | base64 --decode ; echo
	@echo "GITEA_ADMIN"
	echo "r8sA8CPHD9!bt6d | jenkins : amVua2lucwo=" 

gitlab:
	@helm repo add gitlab https://charts.gitlab.io/
	@helm repo update
	@helm upgrade --install gitlab gitlab/gitlab \
		--timeout 600s \
		--set global.edition=ce \
		--set global.hosts.domain=gitlab.localhost.com \
		--set certmanager.install=false \
		--set global.hosts.externalIP=172.18.0.50 \
		--set global.ingress.configureCertmanager=false \
		--set gitlab-runner.install=true \
		--set global.ingress.class=ingress-nginx \
		--set postgresql.image.tag=13.6.0