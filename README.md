# Criação do Cluster

Antes de iniciar qualquer processo no nosso cluster Kind, vamos configurar alguns limites de arquivos abertos. Isso é importante porque tudo vai rodar localmente, então vai acabar usando os limites do sistema host mesmo. Aqui tem uma referência de problema que já ocorreu:

[3 control-plane node setup not starting · Issue #2744 · kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind/issues/2744#issuecomment-1127808069)

```bash
$ echo fs.inotify.max_user_watches=655360 | sudo tee -a /etc/sysctl.conf
$ echo fs.inotify.max_user_instances=1280 | sudo tee -a /etc/sysctl.conf
$ sudo sysctl -p
```

Com isso vamos iniciar a criação do nosso cluster com o seguinte arquivo de configuração:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
- role: worker
- role: worker
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.localhost.com"]
      endpoint = ["<https://harbor.localhost.com>"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.localhost.com".tls]
        insecure_skip_verify = true
```

```bash
$ kind create cluster --config config.yaml
```

## Makefile

Como vocês já sabem pelos outros treinamentos, eu sou um grande fã do uso do Makefile, ainda mais para trabalhar em projetos localmente. Vamos iniciar um Makefile e ir melhorando ao longo do treinamento. Recomendo a esse [leitura](https://alexharv074.github.io/2019/12/26/gnu-make-for-devops-engineers.html) complementar.

```makefile
create:
	@kind create cluster --config config.yaml

down:
	@kind delete clusters kind
```

Com isso podemos subir e destruir o cluster assim:

```bash
$ make create
$ make down
```

## Configurando /etc/hosts (manual)

Para que os nodes consigam falar corretamente com as URLs expostas no nosso Ingress, e sem um DNS, precisamos configurar no /etc/hosts.

```bash
docker network inspect kind
```

```bash
docker container ls
```

```bash
docker container exec -it kind-control-plane sh
```

```sh
ss -ln # para ver o socket
ip a
curl https://172.18.0.4:6443 -Lvk
```

```bash
docker container inspect kind-worker
docker container --filter "label=io.x-k8s.kind.role=worker"
```

```bash
for container in $(docker container ls --filter "label=io.x-k8s.kind.role=worker" -q); do
  # Configure DNS to LoadBalancer
	docker container exec $container \
		bash -c "echo '172.18.0.50 argocd.localhost.com jenkins.localhost.com gitea.localhost.com sonarqube.localhost.com harbor.localhost.com gitlab.localhost.com' >> /etc/hosts"
done
```

## Configurando /etc/hosts (DaemonSet)

Outra opção, e que dá menos trabalho, é deixar um DaemonSet que vai fazer essa configuração para você sempre que iniciar o cluster.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: setup-hosts
  namespace: default
spec:
  selector:
    matchLabels:
      name: setup-hosts
  template:
    metadata:
      labels:
        name: setup-hosts
    spec:
      initContainers:
      - name: setup-hosts
        image: busybox
        command:
          - /bin/sh
          - -c
          - |
            grep jenkins /tmp/hosts || echo '172.21.0.50 argocd.localhost.com jenkins.localhost.com gitea.localhost.com sonarqube.localhost.com harbor.localhost.com' >> /tmp/hosts
        volumeMounts:
        - name: etc
          mountPath: /tmp/hosts
          subPath: hosts
      containers:
      - image: "gcr.io/google-containers/pause:2.0"
        name: pause
      volumes:
      - name: etc
        hostPath:
          path: /etc
```

## Deploy MetalLB

O MetalLB será utilizado para prover endereços IP externos para o LoadBalancer. Dessa forma, poderemos ter um único ponto de entrada (Ingress) roteando para os nossos serviços de infraestrutura internos.

Aqui temos a documentação do MetalLB com Kind (algo mais específico):

### [kind – LoadBalancer](https://kind.sigs.k8s.io/docs/user/loadbalancer/#installing-metallb-using-default-manifests)

verificar o mode do kube-proxy antes

```bash
kubectl get cm -n kube-system kube-proxy -oyaml 
```

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
```

```bash
kubectl wait --namespace metallb-system \
	--for=condition=ready pod \
	--selector=app=metallb \
	--timeout=120s
```

Podemos adicionar um step no nosso Makefile de pre (pré-requisitos) e executar após subir o cluster.

```makefile
pre:
	# ref:
	# https://kind.sigs.k8s.io/docs/user/loadbalancer/#installing-metallb-using-default-manifests
	@kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
	@kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=120s
```

E lembrando que podemos “combar” steps no nosso Makefile.

```makefile
up: create pre
```

E não menos importante, ter um passo default do make.

```makefile
.DEFAULT_GOAL := up
```

```bash
kubectl get pods -n metallb-system --show-labels 
```

## Setup MetalLB

Para que o MetalLB consiga distribuir endereços IP para os Services do tipo LoadBalancer, precisamos configurar a pool.

Vamos escolher um IP baseado na rede do nosso cluster Kubernetes.

Primeiro precisamos identificar qual a rede usada pelo Kind, e com isso a faixa de IP.

```bash
$ docker network ls | grep kind
$ docker inspect <network>
$ docker inspect kind | jq -r '.[].IPAM.Config[0].Subnet'
```

Com isso, vamos preencher o YAML abaixo.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.21.0.50-172.21.0.100
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - homelab-pool
```

Por exemplo, se o endereço da rede é 172.18.0.0/16, a faixa poderia ser como a acima.

Se você estiver em um MacOS ou Windows, provavelmente terá que usar a faixa de IPs da rede da sua casa (exemplo 192.168…). Somente o Linux suporta o envio de requests direto para o Docker container.

## Deploy NGINX Ingress Controller

Helm é a forma meio que “padrão” para instalação de aplicações no Kubernetes por vário motivos. O principal talvez seja ter tudo o que a aplicação precisa empacotado.

Bom, vamos fazer a instalação e personalização do NGINX Ingress Controller e verificar seu comportamento.

```bash
$ helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
$ helm repo update
$ helm search repo ingress-nginx
$ helm upgrade --install \
		--namespace ingress-nginx \
		--create-namespace \
		-f values/ingress-nginx/values.yaml \
		ingress-nginx ingress-nginx/ingress-nginx
```

```bash
helm template nginx ingress-nginx/ingress-nginx
```

Você pode extrair o values.yaml default de várias formas. Eu costumo pegar direto do GitHub. Exemplo para a versão 4.8.3:

## Introdução ao Helmfile

Como você já deve ter percebido, esse processo de configurar values e instalar manualmente é chato. Por mais que isso seja muito mai simples que montar os manifestos um a um, ainda é possível melhorar e cria um processo que possa se repetir mais facilmente.

Com isso em mente, quero apresentar uma ferramenta incrível que poucos conhecem: Helmfile.

Ele é um orquestrador para Helm, uma camada de abstração em cima dele, de forma declarativa.

[GitHub - helmfile/helmfile: Declaratively deploy your Kubernetes manifests, Kustomize configs, and Charts as Helm releases. Generate all-in-one manifests for use with ArgoCD](https://github.com/helmfile/helmfile).

[helmfile](https://helmfile.readthedocs.io/en/latest/#configuration)

```bash
sudo pacman install helmfile
helm plugin install https://github.com/databus23/helm-diff
```

## Migrando NGINX para Helmfile

```yaml
repositories:
  - name: nginx
    url: https://kubernetes.github.io/ingress-nginx

releases:
- name: ingress-nginx
  namespace: ingress-nginx
  createNamespace: true
  chart: nginx/ingress-nginx
  version: 4.4.2
  values:
    - values/nginx/values.yaml
```

```bash
$ helmfile apply
```

Agora é basicamente ir declarando outras releases de outras ferramentas e ir dando o helmfile apply para instalar.

Também fica legal adicionar isso no nosso Makefile.

```makefile
helm:
	@helmfile apply

up: create pre helm
```

## Deploy Jenkins

Aqui estão os repos:

[GitHub - jenkinsci/helm-charts: Jenkins helm charts](https://github.com/jenkinsci/helm-charts)

[helm-chart](https://gitea.com/gitea/helm-chart)

O Jenkins será o nosso CI/CD, e o Gitea será o nosso SCM (onde vamos armazenar o código da aplicação).

A única coisa que vamos modificar nesse primeiro momento é o Ingress, expondo em uma URL que vamos “hardcodar” localmente rsrs.

```yaml
ingress:
  enabled: true
  className: nginx
  annotations: {}
  hosts:
    - host: gitea.localhost.com
      paths:
        - path: /
          pathType: Prefix
```

## Deploy Harbor

Ele funciona como registery de imagens

[GitHub - goharbor/harbor-helm: The helm chart to deploy Harbor](https://github.com/goharbor/harbor-helm)

Quanto ao Harbor, há algumas mudanças que precisamos fazer para que tudo ocorra como planejado.

```yaml
expose:
  type: ingress
  tls:
    enabled: false

ingress:
  hosts:
    core: harbor.localhost.com

externalURL: http://harbor.localhost.com
```

## Deploy SonarQube

[GitHub - SonarSource/helm-chart-sonarqube](https://github.com/SonarSource/helm-chart-sonarqube)

Já o Sonarqube vamos alterar somente o Ingress mesmo.

```yaml
ingress:
  enabled: true
  # Used to create an Ingress record.
  hosts:
    - name: sonarqube.localhost.com
```

## Deploy ArgoCD

Não menos importante, vamos usar o ArgoCD como nossa ferramenta de GitOps (sincronizar o cluster à partir do Git), enquanto o ImagePullSecret-Patcher vai garantir que todas as namespaces e ServiceAccounts tenham o secret necessário para fazer pull de imagens do Harbor.

Começando pelo ArgoCD, vamos configurar ele para rodar como HTTP.

```yaml
server.insecure: true

ingress:
  enabled: true
  hosts:
  - argocd.localhost.com
```

## Deploy ImagePullSecret-Patcher

Quanto ao ImagePullSecret-Patcher, o único parâmetro que temos que personalizar é o secretName:

secretName: "harbor-credentials"

Isto é, o secret que ele deve injetar em todas as ServiceAccounts de todas as namespaces. Por enquanto esse secret ainda não existe, pois quero mostrar o problema ocorrendo futuramente, para depois ajustarmos tudo.

## Organização inicial no Gitea

Podemos clonar o repositório remoto por HTTPS ou SSH. Sempre prefira SSH, porque é uma conexão encriptada utilizando chaves assimétricas, isto é, além de seguro você não precisa digitar senha a cada ação.

Vá no canto superior direito → Settings → SSH / GPG Keys.

Adicione a sua chave pública.

Caso você não saiba ou não tenha chaves SSH, veja o Módulo 23 do Formação Linux, ou assista [esse meu vídeo](https://www.youtube.com/watch?v=6I_-dhkluJ0&t) no YouTube.

## Service user no Gitea

Simulando o que seria um ambiente real, vamos criar uma Organization representando a nossa empresa, e com isso sub-times com usuário de serviço (ci ou jenkins). Afinal, ele vai precisar clonar e escrever em alguns repositórios.

## Expondo porta SSH do Gitea pelo Ingress

O NGINX consegue expôr tanto serviços L4 quanto L7. Para isso vamos configurar o values do Chart:

```yaml
tcp:
  22: "gitea/gitea-ssh:22"
```

Com isso, o Service do NGINX vai abrir a porta 22, e qualquer requisição ali, será enviado para o Service gitea-ssh na namespace gitea.

[Exposing TCP and UDP services - Ingress-Nginx Controller](https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/)

Verificar se o host estã a resolver em uma deserminada porta

```bash
nc -v gitea.localhost.com 22
```

Engineer Reverse

```bash
kubectl get services -A | grep 172.18.0.50
```

## Teste service user (git clone)

```bash
git clone git@gitea.localhost.com:pluralsis/restapi-flaks.git
```
