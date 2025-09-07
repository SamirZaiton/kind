# Cluster Kubernetes on Kind
##### K8S de Dev com Ingress e TLS

Provisiona um cluster **Kind** (Kubernetes em Docker) numa VM (ex.: OCI), com rede, balanceamento, armazenamento e TLS prontos para uso em ambientes de desenvolvimento e staging. Inclui um exemplo de aplicação NGINX acessível por domínio com certificado **Let’s Encrypt** emitido via **cert-manager**.

## ✨ O que este projeto instala

* **NGINX Ingress Controller** pronto e exposto via LoadBalancer.&#x20;
* **MetalLB** com pools de IP públicos/privados e anúncios L2.&#x20;
* **Calico** como CNI (rede de pods).
* **NFS server em container** + **NFS Subdir External Provisioner** com `StorageClass` padrão `nfs-storage`.&#x20;
* **Local Docker Registry** para acelerar builds/pulls (port 5000).
* **cert-manager** para emitir certificados Let’s Encrypt (HTTP-01).
* **Sealed Secrets** para versionar segredos com segurança.&#x20;
* **Metrics Server**, ferramentas de debug e utilitários de cluster.

> O script também cria `IPAddressPool` público para o IP da sua VM e ajusta o Service do Ingress para usar esse IP via anotação do MetalLB.&#x20;

## 🧱 Pré-requisitos

* VM Linux com Docker/Kind; porta 80/443 liberadas (e 5000, se usar o registry local).
* DNS dos seus domínios apontando para o **IP público** da VM (A/AAAA).
* `kubectl` na sua máquina (opcional, para acessar remotamente).

## 🚀 Como subir o cluster

> Ajuste seu e-mail em **`CERT_EMAIL`** na linha: *CERT_EMAIL="${CERT_EMAIL:-yourmail@domain.com}* no script `KindStart.sh`

1. **Baixe e rode o script** na VM:

   ```bash
   chmod +x KindStart.sh
   sudo bash KindStart.sh
   ```

   O script:

   * Cria o cluster Kind com mapeamento de portas 80/443.&#x20;
   * Instala e prepara Ingress, MetalLB, NFS provisioner e `StorageClass` padrão.&#x20;
   * Expõe o Ingress no **IP público** da VM via MetalLB.&#x20;

2. **Obtenha o kubeconfig** (já é gerado pelo script em `/root/.kube/` e é copiado para o usuário, ex.: `ubuntu`):

   * Para acessar do seu terminal local, copie o kubeconfig “público” e ajuste o `server` para `https://SEU_IP_PUBLICO:6443`.

3. **(Opcional) Emitentes Let’s Encrypt**
   O script/auxiliar pode criar `ClusterIssuer` **staging** e **prod** (HTTP-01 via Ingress). Depois, basta anotar os Ingress com `cert-manager.io/cluster-issuer: "letsencrypt-prod"`.

## 🌐 App Home de exemplo com TLS

O repositório traz um manifesto de exemplo (`app-nginx-home-deployment.yaml`) que:

* Faz deploy de uma página HTML estática em NGINX.&#x20;
* Cria `Service` do app.&#x20;
* Cria `Ingress` com `ingressClassName: nginx`, anota para o **cert-manager** e usa **TLS** para `YOUR-DOMAIN.com` e `www.YOUR-DOMAIN`.&#x20;

### Aplicando

```bash
kubectl apply -f app-nginx-home-deployment.yaml
kubectl get ingress
kubectl describe certificate -A
```

> Certifique-se de que **[YOUR-DOMAIN.com](http://erivandosena.com.br)** e **[www.YOUR-DOMAIN.com](http://www.erivandosena.com.br)** apontem (DNS A/AAAA) para o **IP público** exposto pelo Service do Ingress (o próprio IP da VM configurado no MetalLB).&#x20;


## 🔐 Segredos (Sealed Secrets)

Se quiser versionar segredos no Git de forma segura, use **Sealed Secrets**.
Essa solução permite criptografar um `Secret` em um recurso `SealedSecret`, que pode ser armazenado até em repositórios públicos. Apenas o **controller** rodando no cluster é capaz de decriptar o conteúdo e gerar o `Secret` real, garantindo que nem mesmo o autor original consiga reverter o processo fora do cluster.

### Como funciona

* O cliente `kubeseal` usa criptografia assimétrica para transformar um `Secret` em `SealedSecret`.
* O controller no cluster (por padrão em `kube-system`) é o único que pode decriptar e aplicar o `Secret`.
* O recurso `SealedSecret` atua como um *template* seguro para gerar `Secrets`, preservando metadados e podendo ter escopos:

  * `strict` (padrão): válido apenas para o mesmo *nome* e *namespace*.
  * `namespace-wide`: pode ser renomeado dentro do namespace.
  * `cluster-wide`: pode ser aplicado em qualquer namespace.

### Instalação

* **Controller**: pode ser instalado via YAML (Kustomize) ou Helm Chart oficial:

  ```bash
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
  helm install sealed-secrets -n kube-system \
    --set-string fullnameOverride=sealed-secrets-controller \
    sealed-secrets/sealed-secrets
  ```
* **kubeseal**: disponível para Linux, macOS (Homebrew/MacPorts) e Nix.
  Exemplo para Linux:

  ```bash
  KUBESEAL_VERSION="0.23.0"
  wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
  tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
  sudo install -m 755 kubeseal /usr/local/bin/kubeseal
  ```

### Uso básico

```bash
# Cria um Secret localmente (não aplicado no cluster)
echo -n "bar" | kubectl create secret generic mysecret \
  --dry-run=client --from-file=foo=/dev/stdin -o json > mysecret.json

# Gera o SealedSecret
kubeseal -f mysecret.json -w mysealedsecret.json

# Aplica com segurança
kubectl create -f mysealedsecret.json
```

### 📜Exemplo hands-on - Roteiro de Instalação


##### 1. Verifique a versão do controller

```bash
kubectl -n kube-system get deployment sealed-secrets-controller -o yaml | grep image:
```

Saída esperada (exemplo):

```
image: docker.io/bitnami/sealed-secrets-controller:0.25.0
```

##### 2. Baixe o binário correspondente

```bash
KUBESEAL_VERSION="0.25.0"

wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
```

##### 3. Extraia o binário

```bash
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
```

##### 4. Instale no sistema

```bash
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

##### 5. Verifique a instalação

```bash
kubeseal --version
```

Saída esperada:

```
kubeseal version: v0.25.0
```

---

##### 6. Teste rápido de funcionamento

1. Crie um Secret de teste:

   ```bash
   echo -n "minhaSenha123" | kubectl create secret generic meu-segredo \
     --dry-run=client --from-file=password=/dev/stdin -o yaml > meu-segredo.yaml
   ```

2. Converta para SealedSecret:

   ```bash
   kubeseal < meu-segredo.yaml > meu-segredo-sealed.yaml
   ```

3. Aplique no cluster:

   ```bash
   kubectl apply -f meu-segredo-sealed.yaml
   ```

4. Confirme que o Secret foi criado:

   ```bash
   kubectl get secret meu-segredo -o yaml
   ```

5. Validação, certificado e troubleshooting
- **Validar arquivo** antes de aplicar:
  ```bash
  kubeseal --validate < meu-segredo-sealed.yaml
  ```
- **Certificado público** (útil para uso offline do `kubeseal`):
  ```bash
  kubeseal --fetch-cert > sealed-secrets-cert.pem
  # depois: kubeseal --cert sealed-secrets-cert.pem < meu-segredo.yaml > meu-segredo-sealed.yaml
  ```
- **Logs do controller**:
  ```bash
  kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=100
  # Evento esperado em sucesso: reason: 'Unsealed'
  ```

### Boas práticas

* **Rotacione chaves e segredos** regularmente:

  * O controller renova automaticamente a chave de selagem a cada 30 dias.
  * Ainda assim, recomenda-se rotacionar periodicamente as senhas/tokens originais.

* **Backup de chaves**: é possível exportar as chaves privadas do controller com `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`.

* **Ambientes restritos**: em clusters onde não se tem acesso a CRDs, o administrador deve instalar o controller antes.

* **Validação**: use `kubeseal --validate` para checar se um arquivo `SealedSecret` foi gerado corretamente.

* **Verificação de imagens**: todas as imagens do controller são assinadas com [cosign](https://github.com/sigstore/cosign).

### Documentação

Mais detalhes, exemplos e casos avançados estão disponíveis no [repositório oficial](https://github.com/bitnami-labs/sealed-secrets) and ["Sealed Secrets" for Kubernetes](./Readme-SS.md).

---

* Instalação do controller e uso do `kubeseal` estão documentados na referência do projeto.&#x20;
* Dicas de uso quando o controller não está em `kube-system` e verificação de imagens estão na seção de FAQ/How-to.&#x20;

## 🧪 Testes & Observabilidade

* `kubectl get nodes -o wide`, `kubectl get svc -A`, `kubectl get ingress -A`
* `kubectl top nodes` / `kubectl top pods` (Metrics Server)
* Acesse `http(s)://YOUR-DOMAIN/` para ver a página do app (hostname e data/hora renderizados via JS).&#x20;

## 🛠️ Solução de problemas

* **Certificado não emite (Pending/Failed)**
  Verifique:

  * DNS apontando corretamente para o IP do Ingress.
  * Anotação `cert-manager.io/cluster-issuer` no Ingress (`letsencrypt-staging` para testar; depois `letsencrypt-prod`).&#x20;
  * Pod do **cert-manager** saudável.

* **Ingress sem IP externo**
  Cheque se o Service `ingress-nginx-controller` está anotado com `metallb.universe.tf/loadBalancerIPs: "SEU_IP_PUBLICO"` e `type: LoadBalancer`.&#x20;

* **PVC não provisiona**
  Veja se o `StorageClass` padrão é `nfs-storage` e se o NFS provisioner está `Running`.&#x20;

## 📁 Estrutura (essencial)

```sh
KindStart.sh                    # Script de provisionamento do cluster (Kind + stack)
app-nginx-home-deployment.yaml  # App NGINX de exemplo com Service e Ingress (TLS)
```

> Dica: para adicionar **novas aplicações/domínios**, basta criar novos `Ingress` com `host` apropriado e a anotação do `ClusterIssuer`. O mesmo emissor **pode** atender múltiplos domínios; não é necessário criar um emissor por domínio. *(O e-mail do ACME é apenas um de contato/conta, não precisa mudar por domínio.)*

## 🤝 Contribuindo

Issues, ideias e PRs são bem-vindos! Siga boas práticas de Git, inclua contexto e logs quando reportar problemas.

---

## 📜 Licença

A Licença Apache 2.0 é uma licença permissiva que permite usar, copiar, modificar e distribuir softwares de forma gratuita, inclusive em produtos comerciais, desde que sejam mantidos os avisos de copyright, a própria licença e as devidas atribuições. Também concede licença de patentes necessárias para o uso do software, mas essa licença é perdida se houver processo de violação de patentes contra outros. Contribuições feitas ao projeto passam automaticamente a seguir os mesmos termos da licença. O trabalho é fornecido "como está", sem garantias de qualquer tipo, e os autores não se responsabilizam por danos decorrentes do uso. Além disso, não autoriza o uso de marcas ou logotipos do autor, exceto para identificar corretamente a origem do software.
