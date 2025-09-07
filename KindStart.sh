#!/bin/bash

#####################################################
# KindStart.sh (Versão Production)
# Script para iniciar um cluster Kind para desenvolvimento local
# Comptibilidade: Linux, macOS, WSL, OCI (Oracle Cloud Infrastructure)
# Author: Erivando Sena <erivandosena@gmail.com>
#####################################################

set -e

# Necessario para registro no ACME
CERT_EMAIL="${CERT_EMAIL:-yourmail@domain.com}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para detectar IP público na OCI
get_oci_public_ip() {
    curl -s https://ifconfig.co || curl -s https://ifconfig.me || curl -s https://icanhazip.com
}

PUBLIC_IP=$(get_oci_public_ip)
echo -e "${GREEN}IP público detectado: ${PUBLIC_IP}${NC}"

PRIVATE_IP=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
echo -e "${GREEN}IP privado detectado: ${PRIVATE_IP}${NC}"

# Garantir que host.docker.internal resolva corretamente
if ! grep -q "host.docker.internal" /etc/hosts; then
  echo "172.17.0.1 host.docker.internal" | sudo tee -a /etc/hosts
  echo -e "${GREEN}Adicionado host.docker.internal → 172.17.0.1 no /etc/hosts${NC}"
else
  echo -e "${YELLOW}host.docker.internal já está no /etc/hosts${NC}"
fi

echo -e "${BLUE}=== Iniciando cluster Kind para desenvolvimento local ===${NC}"

# Função para verificar se uma porta está em uso
check_port_in_use() {
    local port="$1"
    if command -v nc &> /dev/null; then
        nc -z localhost "$port" &> /dev/null && return 0 || return 1
    elif command -v lsof &> /dev/null; then
        lsof -i:"$port" &> /dev/null && return 0 || return 1
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep ":$port " &> /dev/null && return 0 || return 1
    else
        # Se não temos ferramentas para verificar, assumimos que está livre
        return 1
    fi
}

# Função para detectar ambiente WSL
is_wsl() {
    if grep -q microsoft /proc/version || grep -q Microsoft /proc/version; then
        return 0  # É WSL
    else
        return 1  # Não é WSL
    fi
}

# Função para verificar portas críticas do NFS
check_nfs_ports() {
    local nfs_version="$1"
    local conflicts=false

    echo -e "${YELLOW}Verificando portas NFS para versão ${nfs_version}...${NC}"

    # Definir as portas com base na versão do NFS
    local ports=()
    if [ "$nfs_version" = "3" ] || [ -z "$nfs_version" ]; then
        # NFSv3 requer todas estas portas
        ports=(2049 111 32765 32767)
        echo -e "${YELLOW}NFSv3 requer as portas: 2049 (NFS), 111 (rpcbind), 32765 (mountd), 32767 (statd)${NC}"
    else
        # NFSv4 requer apenas a porta 2049
        ports=(2049)
        echo -e "${YELLOW}NFSv4 requer apenas a porta: 2049 (NFS)${NC}"
    fi

    # Verificar cada porta
    for port in "${ports[@]}"; do
        if check_port_in_use "$port"; then
            case "$port" in
                2049)
                    echo -e "${YELLOW}Porta $port (NFS) já está em uso no host.${NC}"
                    ;;
                111)
                    echo -e "${YELLOW}Porta $port (rpcbind) já está em uso no host.${NC}"
                    ;;
                32765)
                    echo -e "${YELLOW}Porta $port (mountd) já está em uso no host.${NC}"
                    ;;
                32767)
                    echo -e "${YELLOW}Porta $port (statd) já está em uso no host.${NC}"
                    ;;
                *)
                    echo -e "${YELLOW}Porta $port (NFS) já está em uso no host.${NC}"
                    ;;
            esac
            conflicts=true
        fi
    done

    if [ "$conflicts" = true ]; then
        return 1  # Há conflitos
    else
        return 0  # Não há conflitos
    fi
}

# Função para encontrar uma porta disponível
find_free_port() {
    local start_port=${1:-20000}
    local end_port=${2:-65535}

    for port in $(seq $start_port $end_port); do
        if ! check_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    echo -e "${RED}Nenhuma porta disponível encontrada no intervalo $start_port-$end_port${NC}" >&2
    return 1
}

# Função para verificar se o NFS está instalado no host
detect_host_nfs() {
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet nfs-server || systemctl is-active --quiet nfs-kernel-server; then
            echo "active"
        fi
    fi

    if command -v service &> /dev/null; then
        if service nfs-server status &>/dev/null || service nfs-kernel-server status &>/dev/null; then
            echo "active"
        fi
    fi

    if command -v dpkg &> /dev/null && dpkg -l | grep -q "nfs-kernel-server\|nfs-common"; then
        echo "installed"
    fi

    if command -v rpm &> /dev/null && rpm -qa | grep -q "nfs-utils"; then
        echo "installed"
        return 0
    fi

    echo "none"
}

# Verificar portas necessárias
PORT_80_IN_USE=false
PORT_443_IN_USE=false
APISERVER_PORT=${APISERVER_PORT:-6443}

if check_port_in_use 80; then
    PORT_80_IN_USE=true
    echo -e "${YELLOW}AVISO: Porta 80 já está em uso.${NC}"
fi

if check_port_in_use 443; then
    PORT_443_IN_USE=true
    echo -e "${YELLOW}AVISO: Porta 443 já está em uso.${NC}"
fi

# Se alguma porta estiver em uso, oferecer opções
if [ "$PORT_80_IN_USE" = true ] || [ "$PORT_443_IN_USE" = true ]; then
    echo -e "${YELLOW}Uma ou mais portas necessárias (80/443) já estão em uso.${NC}"
    echo -e "Por favor, escolha uma opção:"
    echo -e "  1) Usar portas alternativas (recomendado)"
    echo -e "  2) Tentar parar os serviços que estão usando essas portas"
    echo -e "  3) Cancelar a operação"

    read -r -p "Sua escolha (1-3): " PORT_CHOICE
    PORT_CHOICE=${PORT_CHOICE:-1}  # Default é 1 (usar portas alternativas)

    case "$PORT_CHOICE" in
        1)
            # Escolher portas alternativas
            HTTP_PORT=8080
            HTTPS_PORT=8443

            # Permitir personalização
            read -r -p "Digite a porta HTTP alternativa (deixe em branco para 8080): " CUSTOM_HTTP
            read -r -p "Digite a porta HTTPS alternativa (deixe em branco para 8443): " CUSTOM_HTTPS

            # Usar os valores personalizados se fornecidos
            HTTP_PORT="${CUSTOM_HTTP:-$HTTP_PORT}"
            HTTPS_PORT="${CUSTOM_HTTPS:-$HTTPS_PORT}"

            # Verificar se as novas portas estão livres
            if check_port_in_use "$HTTP_PORT"; then
                echo -e "${RED}A porta $HTTP_PORT também está em uso. Por favor, escolha outra.${NC}"
                exit 1
            fi

            if check_port_in_use "$HTTPS_PORT"; then
                echo -e "${RED}A porta $HTTPS_PORT também está em uso. Por favor, escolha outra.${NC}"
                exit 1
            fi

            echo -e "${GREEN}Usando portas alternativas: HTTP=$HTTP_PORT, HTTPS=$HTTPS_PORT${NC}"
            ;;
        2)
            # Tentar parar os serviços que estão usando as portas
            echo -e "${YELLOW}Tentando identificar e parar serviços que estão usando as portas...${NC}"

            if [ "$PORT_80_IN_USE" = true ]; then
                if command -v lsof &> /dev/null; then
                    PORT_80_PROCESS=$(lsof -i:80 -t)
                    if [ -n "$PORT_80_PROCESS" ]; then
                        echo -e "${YELLOW}Processo usando a porta 80: $PORT_80_PROCESS${NC}"
                        read -r -p "Tentar encerrar este processo? (s/N): " KILL_80
                        if [[ "$KILL_80" =~ ^[Ss]$ ]]; then
                            sudo kill -9 "$PORT_80_PROCESS"
                            echo -e "${GREEN}Processo encerrado.${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}Não foi possível identificar o processo usando a porta 80.${NC}"
                    echo -e "${YELLOW}Tente parar serviços como Apache ou Nginx manualmente.${NC}"
                    exit 1
                fi
            fi

if [ "$PORT_443_IN_USE" = true ]; then
                if command -v lsof &> /dev/null; then
                    PORT_443_PROCESS=$(lsof -i:443 -t)
                    if [ -n "$PORT_443_PROCESS" ]; then
                        echo -e "${YELLOW}Processo usando a porta 443: $PORT_443_PROCESS${NC}"
                        read -r -p "Tentar encerrar este processo? (s/N): " KILL_443
                        if [[ "$KILL_443" =~ ^[Ss]$ ]]; then
                            sudo kill -9 "$PORT_443_PROCESS"
                            echo -e "${GREEN}Processo encerrado.${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}Não foi possível identificar o processo usando a porta 443.${NC}"
                    exit 1
                fi
            fi

            # Verificar novamente se as portas foram liberadas
            sleep 2
            if check_port_in_use 80 || check_port_in_use 443; then
                echo -e "${RED}Não foi possível liberar as portas. Tente a opção de portas alternativas.${NC}"
                exit 1
            fi

            # Portas padrão
            HTTP_PORT=80
            HTTPS_PORT=443
            ;;
        3)
            echo -e "${RED}Operação cancelada pelo usuário.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Opção inválida. Saindo.${NC}"
            exit 1
            ;;
    esac
else
    # Se as portas estiverem livres, usar as portas padrão
    HTTP_PORT=80
    HTTPS_PORT=443
fi

# Função para instalar o Kind
install_kind() {
    echo -e "${YELLOW}Instalando Kind...${NC}"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        echo -e "${YELLOW}Detectado sistema Linux. Instalando Kind...${NC}"

        # Verificar se curl está instalado
        if ! command -v curl &> /dev/null; then
            echo -e "${YELLOW}Instalando curl...${NC}"
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y curl
            elif command -v yum &> /dev/null; then
                sudo yum install -y curl
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y curl
            else
                echo -e "${RED}Não foi possível instalar curl. Por favor, instale manualmente.${NC}"
                exit 1
            fi
        fi

        # Instalar Kind
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind

    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        echo -e "${YELLOW}Detectado sistema macOS. Instalando Kind...${NC}"

        if command -v brew &> /dev/null; then
            brew install kind
        else
            curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-darwin-amd64
            chmod +x ./kind
            sudo mv ./kind /usr/local/bin/kind
        fi

    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
        # Windows
        echo -e "${YELLOW}Detectado sistema Windows. Por favor, instale Kind manualmente:${NC}"
        echo -e "${BLUE}https://kind.sigs.k8s.io/docs/user/quick-start/#installation${NC}"
        exit 1
    else
        echo -e "${RED}Sistema operacional não suportado.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Kind instalado!${NC}"
}

# Função para instalar kubectl
install_kubectl() {
    echo -e "${YELLOW}Instalando kubectl...${NC}"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/

    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install kubectl
        else
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
        fi

    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
        # Windows
        echo -e "${YELLOW}Por favor, instale kubectl manualmente:${NC}"
        echo -e "${BLUE}https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/${NC}"
        exit 1
    fi

    echo -e "${GREEN}kubectl instalado!${NC}"
}

# Função para garantir que o módulo NFS esteja disponível
ensure_nfs_kernel_support() {
    echo -e "${YELLOW}Verificando suporte a NFS no kernel do host...${NC}"

    # Verifica se o módulo nfsd já está carregado
    if lsmod | grep -q nfsd; then
        echo -e "${GREEN}Módulo nfsd já está carregado.${NC}"
        return 0
    fi

    # Instala pacotes necessários (se módulo não existir)
    if ! modinfo nfsd &>/dev/null; then
        echo -e "${YELLOW}Instalando pacotes NFS no host...${NC}"
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y nfs-kernel-server
        elif command -v yum &>/dev/null; then
            sudo yum install -y nfs-utils
        else
            echo -e "${RED}Distribuição não suportada. Instale manualmente:"
            echo -e "Debian/Ubuntu: sudo apt install nfs-kernel-server"
            echo -e "RHEL/CentOS: sudo yum install nfs-utils${NC}"
            exit 1
        fi
    fi

    # Carrega o módulo
    echo -e "${YELLOW}Carregando módulo nfsd...${NC}"
    sudo modprobe nfsd || {
        echo -e "${RED}Falha ao carregar nfsd. Abortando.${NC}"
        exit 1
    }

    echo -e "${GREEN}Suporte a NFS configurado no host.${NC}"
}

# Função para gerenciar o container NFS
manage_nfs_container() {
    local NFS_VERSION="$1"
    local NFS_EXPORT_OPTS="$2"

    # Validar opções de exportação
    validate_nfs_exports() {
        local exports="$1"
        if [[ ! "$exports" =~ .*rw.* ]]; then
            echo -e "${YELLOW}Aviso: Opções de exportação não incluem 'rw'. Adicionando para permitir escrita.${NC}"
            exports="rw,$exports"
        fi

        if [[ "$exports" =~ .*no_root_squash.* ]]; then
            echo -e "${YELLOW}Nota: Usando 'no_root_squash' que permite acesso root ao volume (necessário para Kubernetes).${NC}"
        fi

        echo "$exports"
    }

    NFS_EXPORT_OPTS=$(validate_nfs_exports "$NFS_EXPORT_OPTS")

    # Remover container NFS existente, se houver
    if docker ps -a | grep -q "nfs-server"; then
        echo -e "${YELLOW}Removendo container NFS existente...${NC}"
        docker stop nfs-server 2>/dev/null && sleep 3 || true
        docker rm -f nfs-server 2>/dev/null || true
    fi

    # Criar diretórios e garantir permissões
    echo -e "${YELLOW}Criando diretórios para NFS...${NC}"
    sudo mkdir -p /volumes/k8s/{default,persistent,backup}
    sudo chmod -R 777 /volumes/k8s  # Permissões mais amplas para Kubernetes
    sudo chown -R nobody:nogroup /volumes/k8s

    # Iniciar container NFS com configurações apropriadas
    echo -e "${YELLOW}Iniciando container NFS na rede Kind...${NC}"

    # Configuração base do comando Docker run
    local docker_run_cmd=(
        "docker" "run" "-d"
        "--name" "nfs-server"
        "--privileged"
        "--network" "kind"
        "--restart" "unless-stopped"
        "--health-cmd" "rpcinfo || exit 1"
        "--health-interval" "10s"
        "--health-retries" "3"
        "-v" "/volumes/k8s:/nfsshare"
        "-e" "NFS_CHOWN_NOBODY=true"
        "-e" "NFS_EXPORT_0=/nfsshare *(rw,sync,fsid=0)"
        "-e" "NFS_EXPORT_1=/nfsshare/default *(rw,sync,no_subtree_check,no_root_squash,insecure,no_auth_nlm)"
        "-e" "NFS_EXPORT_2=/nfsshare/persistent *(rw,sync,no_subtree_check,no_root_squash,insecure,no_auth_nlm)"
        "-e" "NFS_EXPORT_3=/nfsshare/backup *(rw,sync,no_subtree_check,no_root_squash,insecure,no_auth_nlm)"
        "-e" "NFS_VERSION=${NFS_VERSION}"
        "-l" "app=nfs-server"
    )

    # Configurações específicas para NFSv4
    if [ "$NFS_VERSION" = "4" ]; then
        docker_run_cmd+=("-e" "IDMAPD_DOMAIN=local.domain")
        echo -e "${GREEN}Configurado NFSv4 com mapeamento de IDs${NC}"
    fi

    # Adicionar mapeamento de portas apenas se estiver usando portas alternativas
    if [ "$USE_ALTERNATIVE_NFS_PORTS" = true ]; then
        docker_run_cmd+=("-p" "${NFS_PORT}:2049")

        # NFSv3 requer mais portas
        if [ "$NFS_VERSION" = "3" ]; then
            docker_run_cmd+=("-p" "${RPCBIND_PORT}:111")
            docker_run_cmd+=("-p" "${MOUNTD_PORT}:32765")
            docker_run_cmd+=("-p" "${STATD_PORT}:32767")
            docker_run_cmd+=("-e" "MOUNTD_PORT=${MOUNTD_PORT}")
            docker_run_cmd+=("-e" "RPCBIND_PORT=${RPCBIND_PORT}")
            docker_run_cmd+=("-e" "STATD_PORT=${STATD_PORT}")
        fi

        docker_run_cmd+=("-e" "NFS_PORT=${NFS_PORT}")
        echo -e "${GREEN}Usando portas alternativas para NFS: ${NFS_PORT}, ${RPCBIND_PORT}, ${MOUNTD_PORT}, ${STATD_PORT}${NC}"
    else
        echo -e "${GREEN}Usando NFS apenas na rede interna do cluster, sem mapear portas para o host${NC}"
    fi

    # Adicionar imagem do container
    docker_run_cmd+=("erichough/nfs-server")

    # Executar o comando
    "${docker_run_cmd[@]}"

    # Aguardar inicialização do NFS
    echo -e "${YELLOW}Aguardando inicialização do servidor NFS...${NC}"
    local max_attempts=20  # Mais tentativas para garantir inicialização completa
    local attempt=0
    local container_running=false

    while [ $attempt -lt $max_attempts ]; do
        sleep 3  # Espera maior entre tentativas
        attempt=$((attempt+1))

        if ! docker ps | grep -q "nfs-server"; then
            echo -e "${YELLOW}Tentativa $attempt/$max_attempts: Container NFS ainda não está pronto...${NC}"
            continue
        fi

        # Verificação mais completa do serviço NFS
        if docker exec nfs-server rpcinfo -p 2>/dev/null | grep -q "nfs" && \
           docker exec nfs-server exportfs -v 2>/dev/null | grep -q "/nfsshare"; then
            echo -e "${GREEN}Servidor NFS completamente inicializado e pronto!${NC}"
            container_running=true
            break
        fi

        # Verificar saúde do container como backup
        health_status=$(docker inspect --format='{{.State.Health.Status}}' nfs-server 2>/dev/null || echo "unknown")
        if [ "$health_status" = "healthy" ]; then
            container_running=true
            break
        fi

        echo -e "${YELLOW}Tentativa $attempt/$max_attempts: Container iniciado, aguardando serviço NFS...${NC}"
    done

    if ! $container_running; then
        echo -e "${RED}Erro: Container NFS não iniciou corretamente${NC}"
        docker logs nfs-server
        exit 1
    fi

    echo -e "${GREEN}Container NFS iniciado!${NC}"

    # Mostrar informações de exportação para referência
    echo -e "${YELLOW}Exportações NFS disponíveis:${NC}"
    docker exec nfs-server exportfs -v
}

# Verificar se o kind está instalado
if ! command -v kind &> /dev/null; then
    echo -e "${RED}Kind não está instalado.${NC}"

    read -r -p "Deseja instalar o Kind automaticamente? (S/n): " INSTALL_KIND
    INSTALL_KIND="${INSTALL_KIND:-S}"  # Default é Sim

    if [[ "$INSTALL_KIND" =~ ^[Ss]$ ]]; then
        install_kind
    else
        echo -e "${YELLOW}Por favor, instale Kind manualmente:${NC}"
        echo -e "${BLUE}https://kind.sigs.k8s.io/docs/user/quick-start/#installation${NC}"
        exit 1
    fi
fi

# Verificar se o kubectl está instalado
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl não está instalado.${NC}"

    read -r -p "Deseja instalar o kubectl automaticamente? (S/n): " INSTALL_KUBECTL
    INSTALL_KUBECTL="${INSTALL_KUBECTL:-S}"  # Default é Sim

    if [[ "$INSTALL_KUBECTL" =~ ^[Ss]$ ]]; then
        install_kubectl
    else
        echo -e "${YELLOW}Por favor, instale kubectl manualmente:${NC}"
        echo -e "${BLUE}https://kubernetes.io/docs/tasks/tools/install-kubectl/${NC}"
        exit 1
    fi
fi

# Perguntar ao usuário o nome do cluster
read -r -p "Digite o nome do cluster (deixe em branco para usar 'k8s-local'): " INPUT_CLUSTER_NAME
CLUSTER_NAME="${INPUT_CLUSTER_NAME:-k8s-local}"

# Verificar se existe um arquivo de imagens salvas do cluster
IMAGES_DIR="$HOME/.kind/images/${CLUSTER_NAME}"
SAVED_IMAGES=false

if [ -d "$IMAGES_DIR" ] && [ "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]; then
    SAVED_IMAGES=true
    echo -e "${YELLOW}Imagens salvas do cluster anterior detectadas.${NC}"
    read -r -p "Deseja usar essas imagens para pré-carregar no novo cluster? (S/n): " USE_SAVED_IMAGES
    USE_SAVED_IMAGES="${USE_SAVED_IMAGES:-S}"  # Default é Sim
fi

# Parte 0: Registro Docker Local
REGISTRY_NAME='kind-registry'
REGISTRY_PORT='5000'

# Perguntar sobre criar um registro local
read -r -p "Criar um registro local para o cluster (recomendado)? (S/n): " CREATE_REGISTRY
CREATE_REGISTRY="${CREATE_REGISTRY:-S}"  # Default é Sim

if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
    # Verificar se o registro já existe
    if [ "$(docker ps -q -f name=^/"${REGISTRY_NAME}"$)" ]; then
        echo -e "${YELLOW}Registro Docker local já está em execução.${NC}"
    else
        # Verificar se a porta 5000 está disponível
        if check_port_in_use 5000; then
            echo -e "${YELLOW}Porta 5000 já está em uso. Escolhendo uma porta alternativa para o registro.${NC}"
            for port in {5001..5010}; do
                if ! check_port_in_use "$port"; then
                    REGISTRY_PORT="$port"
                    break
                fi
            done
        fi

        echo -e "${YELLOW}Criando registro Docker local na porta ${REGISTRY_PORT}...${NC}"
        docker run -d --restart=always -p "${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2
    fi
fi

# Perguntar sobre pré-carregamento de imagens
echo -e "${YELLOW}Deseja pré-carregar imagens Docker no cluster?${NC}"
echo -e "Isso acelera o desenvolvimento pois evita problemas de conectividade e downloads repetidos."
read -r -p "Pré-carregar imagens? (S/n): " PRELOAD_IMAGES
PRELOAD_IMAGES="${PRELOAD_IMAGES:-S}"  # Default é Sim

if [[ "$PRELOAD_IMAGES" =~ ^[Ss]$ ]]; then
    # Perguntar qual método de escolha de imagens
    echo -e "\n${YELLOW}Como deseja selecionar as imagens para pré-carregar?${NC}"
    echo -e "  1) Usar uma seleção padrão recomendada"
    echo -e "  2) Selecionar imagens de categorias pré-definidas"
    echo -e "  3) Carregar imagens específicas (inserção manual)"
    echo -e "  4) Carregar imagens de um arquivo de configuração"

    read -r -p "Selecione uma opção (1-4): " IMAGE_SELECTION_MODE
    IMAGE_SELECTION_MODE="${IMAGE_SELECTION_MODE:-1}"  # Default é usar seleção padrão

    # Inicializar array de imagens vazio
    IMAGES_TO_LOAD=()

    case "$IMAGE_SELECTION_MODE" in
        1)
            # Usar uma seleção básica recomendada
            echo -e "${YELLOW}Usando seleção padrão recomendada...${NC}"
            IMAGES_TO_LOAD=(
                "busybox:1.35.0"       # Ferramenta de diagnóstico básica
                "nicolaka/netshoot"    # Ferramenta de diagnóstico de rede avançada
            )
            ;;
        2)
            # Selecionar imagens por categoria
            echo -e "${YELLOW}Selecione as categorias de imagens a carregar:${NC}"

            # Databases
            read -r -p "Carregar bancos de dados (PostgreSQL, MariaDB)? (s/N): " LOAD_DBS
            if [[ "$LOAD_DBS" =~ ^[Ss]$ ]]; then
                IMAGES_TO_LOAD+=(
                    "postgres:14-alpine"
                    "mariadb:11.3.2"
                )
            fi

            # Web Servers
            read -r -p "Carregar servidores web (Nginx)? (s/N): " LOAD_WEB
            if [[ "$LOAD_WEB" =~ ^[Ss]$ ]]; then
                IMAGES_TO_LOAD+=(
                    "nginx:latest"
                )
            fi

            # Caching
            read -r -p "Carregar sistemas de cache (Redis)? (s/N): " LOAD_CACHE
            if [[ "$LOAD_CACHE" =~ ^[Ss]$ ]]; then
                IMAGES_TO_LOAD+=(
                    "redis:alpine"
                )
            fi

            # Tools
            read -r -p "Carregar ferramentas de diagnóstico (busybox, netshoot)? (S/n): " LOAD_TOOLS
            LOAD_TOOLS="${LOAD_TOOLS:-S}"  # Default é Sim
            if [[ "$LOAD_TOOLS" =~ ^[Ss]$ ]]; then
                IMAGES_TO_LOAD+=(
                    "busybox:1.35.0"
                    "nicolaka/netshoot"
                )
            fi
            ;;
        3)
            # Carregar imagens específicas (inserção manual)
            echo -e "${YELLOW}Inserção manual de imagens.${NC}"
            echo -e "Insira as imagens no formato 'imagem:tag' (ex: nginx:latest)."
            echo -e "Digite uma imagem por linha. Deixe em branco e pressione Enter para terminar."

            while true; do
                read -r -p "Imagem (ou deixe em branco para terminar): " IMAGE_INPUT
                if [ -z "$IMAGE_INPUT" ]; then
                    break
                fi
                IMAGES_TO_LOAD+=("$IMAGE_INPUT")
            done
            ;;
        4)
            # Carregar imagens de um arquivo de configuração
            read -r -p "Digite o caminho para o arquivo com a lista de imagens: " IMAGES_FILE
            if [ -f "$IMAGES_FILE" ]; then
                while IFS= read -r line || [ -n "$line" ]; do
                    # Ignorar linhas em branco e comentários
                    if [ -n "$line" ] && [[ ! "$line" =~ ^#.* ]]; then
                        IMAGES_TO_LOAD+=("$line")
                    fi
                done < "$IMAGES_FILE"
                echo -e "${GREEN}Carregadas ${#IMAGES_TO_LOAD[@]} imagens do arquivo.${NC}"
            else
                echo -e "${RED}Arquivo não encontrado: $IMAGES_FILE${NC}"
                echo -e "${YELLOW}Continuando sem pré-carregar imagens.${NC}"
                IMAGES_TO_LOAD=()
            fi
            ;;
        *)
            echo -e "${RED}Opção inválida. Usando seleção padrão mínima.${NC}"
            IMAGES_TO_LOAD=(
                "busybox:1.35.0"
                "nicolaka/netshoot"
            )
            ;;
    esac
fi

# Parte 1: Criação da rede Docker kind
if ! docker network inspect kind >/dev/null 2>&1; then
  echo -e "${YELLOW}Criando rede Docker 'kind'...${NC}"
  docker network create kind
fi

# Parte 2: Configurando o registry para a rede kind
if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
    docker network connect kind "${REGISTRY_NAME}" || true

    # Configuração para que o Kind possa puxar imagens do registry local
    mkdir -p ~/.config/kind
    cat <<EOF > ~/.config/kind/registries.yaml
mirrors:
  "localhost:${REGISTRY_PORT}":
    endpoint:
      - http://kind-registry:${REGISTRY_PORT}
      # - http://kind-registry:5000
EOF
fi

# Ativar IP forwarding (requer sudo)
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    echo -e "${YELLOW}Ativando IP forwarding...${NC}"
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
fi

# Parte 3: Verificação de portas no firewall
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}UFW está ativo. Permitindo tráfego para portas utilizadas (80, 443, etc)...${NC}"
    sudo ufw allow "$HTTP_PORT"/tcp
    sudo ufw allow "$HTTPS_PORT"/tcp
    sudo ufw allow "$REGISTRY_PORT"/tcp
    sudo ufw allow "$APISERVER_PORT"/tcp
    sudo ufw allow 2049/tcp  # NFS
    sudo ufw allow 111/tcp   # RPC bind
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker não está instalado. É necessário para o NFS em container.${NC}"
    exit 1
fi

# Variáveis para controle de portas NFS alternativas
USE_ALTERNATIVE_NFS_PORTS=false
NFS_PORT=2049
MOUNTD_PORT=32765
RPCBIND_PORT=111
STATD_PORT=32767
NFS_SERVICES_STOPPED=""

# Função para restaurar serviços NFS se foram parados
restore_nfs_services() {
    if [ -n "$NFS_SERVICES_STOPPED" ]; then
        echo -e "${YELLOW}Restaurando serviços NFS que foram parados...${NC}"
        for service in $NFS_SERVICES_STOPPED; do
            echo -e "${YELLOW}Iniciando $service...${NC}"
            sudo systemctl start $service
        done
    fi
}

# Registra função para ser executada ao sair do script
trap restore_nfs_services EXIT

# Parte 4: Preparação para NFS
SETUP_NFS=false
read -r -p "Configurar persistência NFS via container? (S/n): " SETUP_NFS_INPUT
if [[ "$SETUP_NFS_INPUT" =~ ^[Ss]$ ]]; then
    SETUP_NFS=true

    # Verificar conflitos com NFS no host
    NFS_STATUS=$(detect_host_nfs)

    if [ "$NFS_STATUS" != "none" ] || ! check_nfs_ports; then
        echo -e "${YELLOW}Detectado possível conflito com NFS no host.${NC}"
        echo -e "Escolha uma opção:"
        echo -e "  1) Tentar usar portas alternativas para NFS em container (recomendado)"
        echo -e "  2) Tentar parar temporariamente os serviços NFS locais"
        echo -e "  3) Continuar mesmo assim (pode falhar)"
        echo -e "  4) Cancelar a operação"

        read -r -p "Sua escolha (1-4): " NFS_CONFLICT_CHOICE
        NFS_CONFLICT_CHOICE=${NFS_CONFLICT_CHOICE:-1}
        case "$NFS_CONFLICT_CHOICE" in
            1)
                # Usar portas alternativas
                USE_ALTERNATIVE_NFS_PORTS=true
                NFS_PORT=$(find_free_port 20000 30000)
                MOUNTD_PORT=$(find_free_port 30001 40000)
                RPCBIND_PORT=$(find_free_port 40001 50000)
                STATD_PORT=$(find_free_port 50001 60000)

                echo -e "${GREEN}Usando portas alternativas para NFS:${NC}"
                echo -e "  NFS: $NFS_PORT (ao invés de 2049)"
                echo -e "  MOUNTD: $MOUNTD_PORT (ao invés de 32765)"
                echo -e "  RPCBIND: $RPCBIND_PORT (ao invés de 111)"
                echo -e "  STATD: $STATD_PORT (ao invés de 32767)"
                ;;
            2)
                # Parar serviços NFS temporariamente
                echo -e "${YELLOW}Tentando parar serviços NFS locais...${NC}"

                for service in nfs-server nfs-kernel-server rpcbind; do
                    if systemctl is-active --quiet $service 2>/dev/null; then
                        echo -e "  Parando $service..."
                        sudo systemctl stop $service
                        NFS_SERVICES_STOPPED="$NFS_SERVICES_STOPPED $service"
                    fi
                done

                # Verificar se as portas foram liberadas
                if ! check_nfs_ports; then
                    echo -e "${RED}Não foi possível liberar todas as portas NFS.${NC}"
                    echo -e "${YELLOW}Tentando usar portas alternativas...${NC}"
                    USE_ALTERNATIVE_NFS_PORTS=true
                    NFS_PORT=$(find_free_port 20000 30000)
                    MOUNTD_PORT=$(find_free_port 30001 40000)
                    RPCBIND_PORT=$(find_free_port 40001 50000)
                    STATD_PORT=$(find_free_port 50001 60000)
                fi
                ;;
            3)
                # Continuar mesmo assim
                echo -e "${YELLOW}Continuando mesmo com possíveis conflitos.${NC}"
                echo -e "${YELLOW}O container NFS pode falhar ao iniciar.${NC}"
                ;;
            4)
                # Cancelar
                echo -e "${RED}Operação cancelada pelo usuário.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida. Usando portas alternativas.${NC}"
                USE_ALTERNATIVE_NFS_PORTS=true
                NFS_PORT=$(find_free_port 20000 30000)
                MOUNTD_PORT=$(find_free_port 30001 40000)
                RPCBIND_PORT=$(find_free_port 40001 50000)
                STATD_PORT=$(find_free_port 50001 60000)
                ;;
        esac
    fi

    echo -e "${YELLOW}Criando diretórios para NFS...${NC}"
    sudo mkdir -p /volumes/k8s/{default,persistent,backup}
    sudo chmod -Rf 755 /volumes/k8s
    sudo chown -Rf nobody:nogroup /volumes/k8s  # Importante para permissões NFS
fi

# Função para obter IP do container NFS
get_nfs_container_ip() {
    local container_name="$1"
    local ip=""

    # Método 1: Inspecionar redes específicas
    ip=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if eq $k "kind"}}{{$v.IPAddress}}{{end}}{{end}}' "$container_name")

    # Método 2: Se método 1 falhar, tentar todas as redes
    if [ -z "$ip" ]; then
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" | head -n1)
    fi

    # Método 3: Usar network inspect
    if [ -z "$ip" ]; then
        ip=$(docker network inspect kind -f '{{range $k, $v := .Containers}}{{if eq $v.Name "'"$container_name"'"}}{{$v.IPv4Address}}{{end}}{{end}}' | cut -d/ -f1)
    fi

    # Fallback
    if [ -z "$ip" ]; then
        ip="host.docker.internal"
    fi

    echo "$ip"
}

# Parte 5: Criação de arquivo de configuração para o Kind
echo -e "${YELLOW}Gerando arquivo de configuração para o Kind...${NC}"
KIND_CONFIG_FILE=$(mktemp)

# Escrevendo a configuração inicial do cluster
cat > "${KIND_CONFIG_FILE}" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: "${CLUSTER_NAME}"
EOF

# Adicionar configuração de registro local, se solicitado
if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
    cat >> "${KIND_CONFIG_FILE}" << EOF
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
    endpoint = ["http://kind-registry:${REGISTRY_PORT}"]
EOF
fi

# Adicionar o resto da configuração
cat >> "${KIND_CONFIG_FILE}" << EOF
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
      - "localhost"
      - "127.0.0.1"
      - "${PRIVATE_IP}"  # IP privado da VM
      - "${PUBLIC_IP}"   # IP público (acesso externo)
      - "host.docker.internal"

  extraPortMappings:
  - containerPort: 80
    hostPort: $((HTTP_PORT))
    protocol: TCP
    listenAddress: "0.0.0.0"
  - containerPort: 443
    hostPort: $((HTTPS_PORT))
    protocol: TCP
    listenAddress: "0.0.0.0"
- role: worker
- role: worker
- role: worker
- role: worker
networking:
  # expor só no IP privado ou mantem "127.0.0.1"
  apiServerAddress: "${PRIVATE_IP}"
  apiServerPort: ${APISERVER_PORT}
  # Configurações para melhorar a estabilidade do DNS
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/16"
  disableDefaultCNI: true
  kubeProxyMode: "iptables"
EOF

# Parte 6: Criação do cluster Kind
echo -e "${YELLOW}Criando cluster Kind com nome: ${CLUSTER_NAME}...${NC}"
kind create cluster --config="${KIND_CONFIG_FILE}"
rm "${KIND_CONFIG_FILE}"

# Parte 7: Instalação do Calico
echo -e "${YELLOW}Instalando Calico para gerenciamento de rede do cluster...${NC}"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s

# Parte 8: Configuração pós-criação do cluster
# Salva kubeconfig interno e gera kubeconfig externo apontando para o IP público
kind get kubeconfig --name "${CLUSTER_NAME}" > "$HOME/.kube/${CLUSTER_NAME}.kubeconfig"
cp "$HOME/.kube/${CLUSTER_NAME}.kubeconfig" "$HOME/.kube/${CLUSTER_NAME}.public.kubeconfig"
# Substitui o endpoint 127.0.0.1:<porta> por https://PUBLIC_IP:APISERVER_PORT
sed -i "s#https://[0-9A-Za-z\.\-]\+:[0-9]\+#https://${PUBLIC_IP}:${APISERVER_PORT}#g" \
  "$HOME/.kube/${CLUSTER_NAME}.public.kubeconfig"

# Mostra o endpoint real do kubeconfig interno
INT_SERVER=$(kubectl config view --kubeconfig "$HOME/.kube/${CLUSTER_NAME}.kubeconfig" --minify -o jsonpath='{.clusters[0].cluster.server}')
echo -e "  API Server (interno): \e[32m${INT_SERVER}\e[0m"
# echo -e "  API Server (interno): \e[32mhttps://127.0.0.1:${APISERVER_PORT}\e[0m"
echo -e "  API Server (externo): \e[32mhttps://${PUBLIC_IP}:${APISERVER_PORT}\e[0m"
echo -e "  kubeconfig interno: \e[32m$HOME/.kube/${CLUSTER_NAME}.kubeconfig\e[0m"
echo -e "  kubeconfig externo: \e[32m$HOME/.kube/${CLUSTER_NAME}.public.kubeconfig\e[0m"

# Carregar imagens salvas anteriormente, se existirem e solicitado
if [[ "$SAVED_IMAGES" == true && "$USE_SAVED_IMAGES" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}Carregando imagens salvas de execução anterior...${NC}"

    for image_file in "$IMAGES_DIR"/*.tar; do
        if [ -f "$image_file" ]; then
            echo -e "${BLUE}Carregando imagem: $(basename "$image_file")${NC}"
            kind load image-archive "$image_file" --name "${CLUSTER_NAME}" || echo -e "${YELLOW}Não foi possível carregar $(basename "$image_file")${NC}"
        fi
    done
fi

# Pré-carregar imagens no cluster, se solicitado
if [[ "$PRELOAD_IMAGES" =~ ^[Ss]$ ]] && [ ${#IMAGES_TO_LOAD[@]} -gt 0 ]; then
    echo -e "${YELLOW}Pré-carregando ${#IMAGES_TO_LOAD[@]} imagens no cluster...${NC}"

    # Tentar puxar e carregar cada imagem
    for image in "${IMAGES_TO_LOAD[@]}"; do
        echo -e "${BLUE}Pré-carregando imagem: ${image}${NC}"
        docker pull "${image}" || echo -e "${YELLOW}Não foi possível baixar ${image}${NC}"
        kind load docker-image "${image}" --name "${CLUSTER_NAME}" || echo -e "${YELLOW}Não foi possível carregar ${image} no cluster${NC}"
    done

    # Se houver um registro local, também pushar as imagens para lá
    if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
        read -r -p "Enviar imagens para o registro local? (s/N): " PUSH_TO_REGISTRY
        if [[ "$PUSH_TO_REGISTRY" =~ ^[Ss]$ ]]; then
            for image in "${IMAGES_TO_LOAD[@]}"; do
                local_image="localhost:${REGISTRY_PORT}/${image}"
                echo -e "${BLUE}Enviando imagem para registro local: ${local_image}${NC}"
                docker tag "${image}" "${local_image}" || echo -e "${YELLOW}Não foi possível criar tag ${local_image}${NC}"
                docker push "${local_image}" || echo -e "${YELLOW}Não foi possível enviar ${local_image} para o registro local${NC}"
            done
        fi
    fi
fi

# Garantir que usuários não-root tenham acesso ao kubectl
echo -e "${YELLOW}Configurando permissões do kubeconfig...${NC}"
if [[ $EUID -eq 0 ]]; then
  # Pegar o nome do usuário não-root original (se estiver usando sudo)
  REAL_USER=$(logname 2>/dev/null || echo "$SUDO_USER")
  if [ -n "$REAL_USER" ]; then
    USER_HOME=$(eval echo ~"$REAL_USER")
    mkdir -p "$USER_HOME"/.kube
    cp -f "$HOME"/.kube/config "$USER_HOME"/.kube/
    chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$USER_HOME"/.kube
    chmod 600 "$USER_HOME"/.kube/config
    echo -e "${GREEN}Configuração do Kubernetes copiada para $USER_HOME/.kube/config${NC}"
    echo -e "${YELLOW}Agora o usuário $REAL_USER pode usar kubectl sem root${NC}"
  fi
else
  # Se executado como usuário normal, garanta que o diretório existe
  mkdir -p "$HOME"/.kube
  chmod 700 "$HOME"/.kube
  chmod 600 "$HOME"/.kube/config 2>/dev/null || true
fi

# Conectar o registro local à rede do Kind, se criado
if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}Configurando acesso ao registro local...${NC}"

    # Configurar cluster para acessar o registro local
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
fi

# Adicionar configuração NFS para persistência de dados
if [[ "$SETUP_NFS" == true ]]; then
    echo -e "${YELLOW}Configurando NFS via container para persistência de dados...${NC}"

        echo -e "${YELLOW}Selecione a versão do NFS a ser utilizada:${NC}"
        echo -e "  1) NFS versão 3 (mais compatível, recomendado) [PADRÃO]"
        echo -e "  2) NFS versão 4 (melhor desempenho)"

        read -r -p "Escolha (1-2, pressione Enter para usar versão 3): " NFS_VERSION_CHOICE
        NFS_VERSION_CHOICE="${NFS_VERSION_CHOICE:-1}"

        # Usar o mesmo NFS_EXPORT_OPTS para ambas as versões
        NFS_EXPORT_OPTS="*(rw,sync,no_subtree_check,no_root_squash,fsid=0,insecure,no_auth_nlm)"

        if [ "$NFS_VERSION_CHOICE" == "1" ]; then
                NFS_VERSION=3
                NFS_MOUNT_OPTIONS="vers=3,tcp,nolock,noacl"
                echo -e "${GREEN}Usando NFS versão 3 (mais compatível)${NC}"
        else
                NFS_VERSION=4
                NFS_MOUNT_OPTIONS="vers=4,minorversion=0,tcp,nolock,noacl"
                echo -e "${YELLOW}Usando NFS versão 4 (melhor desempenho, pode ser menos compatível)${NC}"
        fi

    # Preparar diretórios e criar container NFS
    sudo mkdir -p /volumes/k8s/{default,persistent,backup}
    sudo chmod -Rf 777 /volumes/k8s
    sudo chown -Rf nobody:nogroup /volumes/k8s

    ensure_nfs_kernel_support

    manage_nfs_container "$NFS_VERSION" "$NFS_EXPORT_OPTS"

fi

# Obter IP do container NFS
NFS_SERVER_IP=$(get_nfs_container_ip "nfs-server")

echo -e "${GREEN}Container NFS iniciado com IP: ${NFS_SERVER_IP}${NC}"

# Criar um serviço Kubernetes para o NFS
kubectl create namespace nfs-provisioner 2>/dev/null || true
    echo -e "${YELLOW}Criando serviço Kubernetes para o NFS...${NC}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: nfs-provisioner
spec:
  ports:
  - name: nfs
    port: 2049
    targetPort: 2049
    protocol: TCP
  - name: mountd
    port: 32767
    targetPort: 32767
    protocol: TCP
  - name: rpcbind
    port: 111
    targetPort: 111
    protocol: TCP
  selector:
    app: nfs-server
EOF

echo -e "\n${YELLOW}Configurando NFS StorageClass e Provisioner...${NC}"

# Antes de criar StorageClass, remover qualquer padrão existente
kubectl get storageclass -o name | xargs -I {} kubectl patch {} -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

cat <<'EOF' | sed "s/NFS_SERVER_IP_PLACEHOLDER/$NFS_SERVER_IP/g" | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner
  labels:
    app: nfs-provisioner

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nfs-client-provisioner-config
  namespace: nfs-provisioner
data:
  nfs.server: "NFS_SERVER_IP_PLACEHOLDER"
  nfs.path: "/nfsshare/default"

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner

---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get"]

---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io

---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: nfs-provisioner
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]

---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-provisioner
roleRef:
  kind: Role
  name: leader-locking-nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: nfs-provisioner
  labels:
    app: nfs-client-provisioner
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: k8s.gcr.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            capabilities:
              add: ["DAC_READ_SEARCH", "SYS_ADMIN"]
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
            - name: NFS_SERVER
              valueFrom:
                configMapKeyRef:
                  name: nfs-client-provisioner-config
                  key: nfs.server
            - name: NFS_PATH
              valueFrom:
                configMapKeyRef:
                  name: nfs-client-provisioner-config
                  key: nfs.path
            - name: DEBUG
              value: "true"
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
      volumes:
        - name: nfs-client-root
          nfs:
            server: "NFS_SERVER_IP_PLACEHOLDER"
            path: "/nfsshare/default"

---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  pathPattern: "${.PVC.namespace}/${.PVC.name}/${.PVC.annotations.nfs.io/storage-path}"
  onDelete: retain
  archiveOnDelete: "true"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: false
mountOptions:
  - vers=3
  - tcp
  - nolock
  - noacl
  - rsize=8192
  - wsize=8192
  - hard
  - timeo=600
  - retrans=2
EOF

# Parte 9: Instalação do Ingress Controller (NGINX)
echo -e "${YELLOW}Instalando NGINX Ingress Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/kind/deploy.yaml

# Aguardar o ingress-controller ficar pronto com verificação e timeout
echo -e "\n${YELLOW}Aguardando o Ingress Controller ficar pronto...${NC}"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s || echo -e "${YELLOW}Tempo limite excedido ao aguardar o Ingress Controller. Continuando mesmo assim...${NC}"

# Configurar o Ingress Controller para usar o LoadBalancer com IP específico
echo -e "${YELLOW}Configurando Ingress Controller para usar o IP público ${PUBLIC_IP}...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${PUBLIC_IP}\"}}}"

# Aguardar até que os namespaces estejam disponíveis
sleep 10

# Verificar se o namespace existe
if kubectl get namespace ingress-nginx &>/dev/null; then
    # Verificar se o controlador existe antes de usar wait
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller &>/dev/null; then
        kubectl wait --namespace ingress-nginx \
          --for=condition=ready pod \
          --selector=app.kubernetes.io/component=controller \
          --timeout=300s || echo -e "${YELLOW}Tempo limite excedido ao aguardar o Ingress Controller. Continuando mesmo assim...${NC}"
    else
        echo -e "${YELLOW}Não foi encontrado pod do ingress controller. Verificando deployments...${NC}"
        kubectl get deployments -n ingress-nginx
        kubectl get pods -n ingress-nginx
        echo -e "${YELLOW}Continuando sem aguardar pelo ingress controller...${NC}"
    fi
else
    echo -e "${YELLOW}Namespace ingress-nginx não encontrado. A instalação do Ingress pode ter falhado.${NC}"
    echo -e "${YELLOW}Verificando namespaces disponíveis:${NC}"
    kubectl get namespaces
    echo -e "${YELLOW}Continuando sem Ingress Controller...${NC}"
fi

# Parte 10: Instalação do Sealed Secrets
echo -e "\n${YELLOW}Instalando Sealed Secrets Controller...${NC}"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.25.0/controller.yaml

# Parte 11: Instalação do MetalLB
echo -e "\n${YELLOW}Instalando MetalLB...${NC}"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=available deployment/controller --timeout=180s

# Configurar o Ingress Controller para usar o LoadBalancer com IP específico
echo -e "${YELLOW}Configurando Ingress Controller para usar o IP público ${PUBLIC_IP}...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${PUBLIC_IP}\"}}}"

# Aguardar o controlador do MetalLB
echo -e "\n${YELLOW}Aguardando MetalLB ficar pronto...${NC}"
kubectl wait --namespace metallb-system \
  --for=condition=available deployment/controller \
  --timeout=98s

# Aplicar configuração avançada do IPAddressPool + L2Advertisement
echo -e "\n${YELLOW}Configurando IP Pool avançado do MetalLB...${NC}"

# Obter a interface de rede principal
MAIN_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
echo -e "${GREEN}Interface de rede principal detectada: ${MAIN_INTERFACE}${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: private-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.255.200-172.18.255.250
  serviceAllocation:
    namespaceSelectors:
    - matchExpressions:
      - key: name
        operator: NotIn
        values: [ingress-nginx]
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: public-pool
  namespace: metallb-system
spec:
  addresses:
  - ${PUBLIC_IP}/32
  serviceAllocation:
    namespaceSelectors:
    - matchLabels:
        kubernetes.io/metadata.name: ingress-nginx
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: cluster-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - private-pool
  interfaces:
  - ${MAIN_INTERFACE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ingress-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - public-pool
  interfaces:
  - ${MAIN_INTERFACE}
EOF

# Verificar se a configuração foi aplicada
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system

# Configurar o Ingress Controller para usar o LoadBalancer com IP específico
echo -e "${YELLOW}Configurando Ingress Controller para usar o IP público ${PUBLIC_IP}...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p "{\"metadata\":{\"annotations\":{\"metallb.universe.tf/loadBalancerIPs\":\"${PUBLIC_IP}\"}}}"

# Parte 12: Instalação de ferramentas de debug (debug-tools)
echo -e "${YELLOW}Instalando ferramentas de depuração...${NC}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: debug-tools
  namespace: default
data:
  tools.sh: |
    #!/bin/sh
    apk add --no-cache curl bind-tools iputils busybox-extras netcat-openbsd
---
apiVersion: v1
kind: Pod
metadata:
  name: debug-tools
  namespace: default
spec:
  containers:
  - name: tools
    image: busybox:1.35.0-uclibc
    command: ["sh", "-c", "sleep infinity"]
    volumeMounts:
    - name: tools
      mountPath: /tools
  volumes:
  - name: tools
    configMap:
      name: debug-tools
      defaultMode: 0755
EOF


# Parte 13: Instalação do cert-manager
echo -e "\n${YELLOW}Instalando cert-manager para gerenciamento de certificados TLS...${NC}"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml

# Aguardar a instalação do cert-manager
echo -e "${YELLOW}Aguardando o cert-manager ficar pronto...${NC}"
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=120s || echo -e "${YELLOW}Tempo limite excedido ao aguardar o cert-manager. Continuando...${NC}"

# === Let's Encrypt para todos os domínios/apps) ===
echo -e "${YELLOW}Configurando Let's Encrypt...${NC}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"                # nome do ingressClass usado no cluster (nginx, traefik, etc)
echo -e "\n[LE] Usando email ACME: $CERT_EMAIL e ingressClass: $INGRESS_CLASS"

# 1) garantir cert-manager pronto
kubectl wait -n cert-manager --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager --timeout=180s || {
  echo "[LE] cert-manager não ficou pronto a tempo"; exit 1; }

# 2) criar ClusterIssuer (staging)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${CERT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS}
EOF

# 3) criar ClusterIssuer (prod)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS}
EOF

# 4) validar que ficaram Ready
for ISS in letsencrypt-staging letsencrypt-prod; do
  echo "[LE] Checando ClusterIssuer $ISS..."
  # tenta por até 90s (9x10s)
  for i in {1..9}; do
    READY=$(kubectl get clusterissuer $ISS -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$READY" == "True" ]] && { echo "  -> $ISS Ready"; break; }
    sleep 10
  done
  [[ "$READY" == "True" ]] || { echo "  !! $ISS não ficou Ready"; exit 1; }
done
echo "[LE] ClusterIssuers prontos. Basta anotar nos Ingress."

# Parte 14: Instalação do Metrics Server para suporte ao HPA
echo -e "\n${BLUE}=== Instalando Metrics Server para suporte ao HPA ===${NC}"

# Aplicar o Metrics Server diretamente do repositório oficial
echo -e "${YELLOW}Aplicando manifesto oficial do Metrics Server...${NC}"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Adicionar a flag kubelet-insecure-tls necessária para ambiente Kind
echo -e "${YELLOW}Configurando Metrics Server para ambiente Kind...${NC}"
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Aguardar a instalação do Metrics Server
echo -e "${YELLOW}Aguardando o Metrics Server ficar pronto...${NC}"
kubectl rollout restart deployment metrics-server -n kube-system
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=k8s-app=metrics-server \
  --timeout=120s || echo -e "${YELLOW}Tempo limite excedido ao aguardar o Metrics Server. Continuando...${NC}"

# Verificar a instalação do Metrics Server
echo -e "${YELLOW}Verificando a instalação do Metrics Server após 15 segundos...${NC}"
sleep 15
if kubectl top nodes &>/dev/null; then
  echo -e "${GREEN}✓ Metrics Server funcionando corretamente${NC}"
else
  echo -e "${YELLOW}⚠ Metrics Server ainda não está respondendo. Pode levar alguns minutos para inicializar completamente.${NC}"
fi


# Método 2: Teste via container (definitivo)
echo -e "${YELLOW}Executando teste de NFS a partir da rede do Kind...${NC}"
if docker run --rm --network kind alpine sh -c \
   "apk add nfs-utils >/dev/null 2>&1 && timeout 5 showmount -e $NFS_SERVER_IP" >/dev/null 2>&1; then
  echo -e "${GREEN}✓ NFS operacional (testado dentro do cluster)${NC}"
else
  echo -e "${RED}✗ NFS inacessível. Verifique:${NC}"
  echo -e "  1. Container NFS está rodando? (docker ps | grep nfs-server)"
  echo -e "  2. Exportações estão corretas? (docker exec nfs-server exportfs)"
  echo -e "  3. Firewall bloqueando a rede 'kind'?"
  exit 1
fi

# Verificar se o provisionador está rodando
echo -e "\n${YELLOW}Verificando status do NFS Provisioner...${NC}"
kubectl rollout status deployment/nfs-client-provisioner -n nfs-provisioner --timeout=90s

# Adicionar verificação da StorageClass
echo -e "\n${GREEN}NFS StorageClass configurada!${NC}"
echo -e "${YELLOW}StorageClasses disponíveis:${NC}"
kubectl get storageclass

# Parte 15: Resumo final e verificação do cluster
echo -e "\n${GREEN}Cluster Kind está pronto para uso!${NC}"

# Perguntar por um dominio para o hosts local
read -r -p "Digite um domínio para adicionar ao /etc/hosts (deixe em branco para usar 'k8s.local'): " DOMAIN
DOMAIN="${DOMAIN:-k8s.local}"

# Ajustar instruções com base nas portas usadas
if [ "$HTTP_PORT" = "80" ]; then
    echo -e "\nAcesse a aplicação em: ${BLUE}http://${DOMAIN}/${NC}"
else
    echo -e "\nAcesse a aplicação em: ${BLUE}http://${DOMAIN}:${HTTP_PORT}/${NC}"
fi

echo -e "Adicione ao arquivo /etc/hosts:"
echo -e "${BLUE}127.0.0.1 ${DOMAIN}${NC}"

# Criar um script para verificar o status do cluster
cat << 'EOF' > kind-status.sh
#!/bin/bash
CLUSTER_NAME=$(kind get clusters | head -n1)
echo "Status do cluster Kind: $CLUSTER_NAME"
echo
echo "=== Nodes ==="
kubectl get nodes -o wide
echo
echo "=== Namespaces ==="
kubectl get namespaces
echo
echo "=== Deployments ==="
kubectl get deployments --all-namespaces
echo
echo "=== Services ==="
kubectl get services --all-namespaces
echo
echo "=== Persistent Volumes ==="
kubectl get pv
echo
echo "=== Storage Classes ==="
kubectl get storageclass
EOF
chmod +x kind-status.sh

# Criar script para parar o cluster
cat << 'EOF' > KindStop.sh
#!/bin/bash
# KindStop.sh
# Script para parar um cluster Kind e limpar todos os recursos associados

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}=============================================${NC}"
echo -e "${YELLOW}KindStop.sh - Ferramenta para encerrar cluster Kind${NC}"
echo -e "${BLUE}=============================================${NC}"

# Verificar se o kind está instalado
if ! command -v kind &> /dev/null; then
    echo -e "${RED}Kind não está instalado. Não há clusters para parar.${NC}"
    exit 1
fi

# Obter a lista de clusters Kind
CLUSTERS=$(kind get clusters 2>/dev/null || echo "")

if [ -z "$CLUSTERS" ]; then
    echo -e "${YELLOW}Nenhum cluster Kind encontrado.${NC}"

    # Verificar recursos relacionados
    RESOURCES_FOUND=false
    if docker ps | grep -q "kind-registry"; then
        echo -e "${YELLOW}⚠ Registro Docker 'kind-registry' encontrado.${NC}"
        RESOURCES_FOUND=true
    fi

    if docker ps | grep -q "nfs-server"; then
        echo -e "${YELLOW}⚠ Container NFS 'nfs-server' encontrado.${NC}"
        RESOURCES_FOUND=true
    fi

    if $RESOURCES_FOUND; then
        read -r -p "Deseja limpar esses recursos? (s/N): " CLEAN_RESOURCES
        if [[ "$CLEAN_RESOURCES" =~ ^[Ss]$ ]]; then
            # Limpar registry
            if docker ps | grep -q "kind-registry"; then
                echo -e "${YELLOW}Removendo registro Docker...${NC}"
                docker stop kind-registry 2>/dev/null && docker rm kind-registry 2>/dev/null || \
                    echo -e "${YELLOW}Não foi possível remover o registry.${NC}"
            fi

            # Limpar NFS
            if docker ps | grep -q "nfs-server"; then
                echo -e "${YELLOW}Removendo container NFS...${NC}"
                docker stop nfs-server 2>/dev/null && docker rm -f nfs-server 2>/dev/null || \
                    echo -e "${YELLOW}Não foi possível remover o container NFS.${NC}"
            fi

            echo -e "${GREEN}Recursos limpos.${NC}"
        fi
    fi

    exit 0
fi

# Selecionar cluster para parar
if [ $(echo "$CLUSTERS" | wc -w) -eq 1 ]; then
    CLUSTER_NAME=$CLUSTERS
    echo -e "${GREEN}Único cluster encontrado: ${CLUSTER_NAME}${NC}"
else
    echo -e "${YELLOW}Múltiplos clusters encontrados. Selecione qual deseja parar:${NC}"
    select CLUSTER_NAME in $CLUSTERS "Todos" "Cancelar"; do
        if [ "$CLUSTER_NAME" = "Todos" ]; then
            CLUSTER_NAME="ALL"
            break
        elif [ "$CLUSTER_NAME" = "Cancelar" ]; then
            echo -e "${YELLOW}Operação cancelada.${NC}"
            exit 0
        elif [ -n "$CLUSTER_NAME" ]; then
            break
        else
            echo -e "${RED}Escolha inválida. Tente novamente.${NC}"
        fi
    done
fi

# Função para parar um cluster individual
stop_single_cluster() {
    local cluster=$1

    echo -e "${BLUE}=== Parando cluster: ${cluster} ===${NC}"

    # Perguntar sobre salvar imagens
    read -r -p "Deseja salvar as imagens do cluster para uso futuro? (S/n): " SAVE_IMAGES
    SAVE_IMAGES=${SAVE_IMAGES:-S}

    if [[ "$SAVE_IMAGES" =~ ^[Ss]$ ]]; then
        IMAGES_DIR="$HOME/.kind/images/${cluster}"
        mkdir -p "$IMAGES_DIR"

        echo -e "${YELLOW}Salvando imagens do cluster ${cluster}...${NC}"

        # Obter e salvar imagens
        IMAGES=$(docker exec ${cluster}-control-plane crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[0]' 2>/dev/null || echo "")

        for image in $IMAGES; do
            if [ "$image" != "null" ] && [ -n "$image" ]; then
                IMAGE_FILENAME=$(echo "$image" | tr "/" "_" | tr ":" "_")
                echo -e "${BLUE}Salvando imagem: $image${NC}"
                kind export kubeconfig --name "${cluster}" 2>/dev/null || true
                kind save image "$image" --name "${cluster}" --output "${IMAGES_DIR}/${IMAGE_FILENAME}.tar" 2>/dev/null || \
                    echo -e "${YELLOW}Não foi possível salvar a imagem: $image${NC}"
            fi
        done

        echo -e "${GREEN}Imagens salvas em: ${IMAGES_DIR}${NC}"
    fi

    # Parar cluster
    echo -e "${YELLOW}Removendo o cluster ${cluster}...${NC}"
    kind delete cluster --name "${cluster}" || \
        echo -e "${RED}Não foi possível remover o cluster ${cluster}. Continuando...${NC}"
}

# Parar cluster(s)
if [ "$CLUSTER_NAME" = "ALL" ]; then
    for cluster in $CLUSTERS; do
        stop_single_cluster "$cluster"
    done
    echo -e "${GREEN}Todos os clusters foram removidos.${NC}"
else
    stop_single_cluster "$CLUSTER_NAME"
    echo -e "${GREEN}Cluster ${CLUSTER_NAME} foi removido.${NC}"
fi

# Limpeza adicional
echo -e "${YELLOW}Realizando limpeza adicional...${NC}"

# 1. Remover registro Docker
if docker ps | grep -q "kind-registry"; then
    read -r -p "Remover o registro Docker local 'kind-registry'? (S/n): " REMOVE_REGISTRY
    REMOVE_REGISTRY=${REMOVE_REGISTRY:-S}

    if [[ "$REMOVE_REGISTRY" =~ ^[Ss]$ ]]; then
        echo -e "${YELLOW}Removendo registro Docker...${NC}"
        docker stop kind-registry 2>/dev/null && docker rm kind-registry 2>/dev/null || \
            echo -e "${YELLOW}Não foi possível remover o registry.${NC}"
    fi
fi

# 2. Remover container NFS
if docker ps | grep -q "nfs-server"; then
    read -r -p "Remover o container NFS 'nfs-server'? (S/n): " REMOVE_NFS
    REMOVE_NFS=${REMOVE_NFS:-S}

    if [[ "$REMOVE_NFS" =~ ^[Ss]$ ]]; then
        echo -e "${YELLOW}Removendo container NFS...${NC}"
        docker stop nfs-server 2>/dev/null && docker rm -f nfs-server 2>/dev/null || \
            echo -e "${YELLOW}Não foi possível remover o container NFS.${NC}"
    fi
fi

# 3. Limpar scripts auxiliares
if [ -f "kind-status.sh" ]; then
    read -r -p "Remover scripts auxiliares (kind-status.sh)? (s/N): " REMOVE_SCRIPTS
    REMOVE_SCRIPTS=${REMOVE_SCRIPTS:-N}

    if [[ "$REMOVE_SCRIPTS" =~ ^[Ss]$ ]]; then
        echo -e "${YELLOW}Removendo scripts auxiliares...${NC}"
        rm -f kind-status.sh 2>/dev/null || true
    fi
fi

# Resumo final
echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}LIMPESA CONCLUÍDA${NC}"
echo -e "${BLUE}==============================================${NC}"

# Verificar containers remanescentes
REMAINING_CONTAINERS=$(docker ps --format "{{.Names}}" | grep "kind-\|nfs-server\|kind-registry" | tr '\n' ' ')

if [ -n "$REMAINING_CONTAINERS" ]; then
    echo -e "${YELLOW}Containers remanescentes: ${REMAINING_CONTAINERS}${NC}"
    echo -e "${YELLOW}Use 'docker rm -f' para removê-los manualmente se necessário.${NC}"
else
    echo -e "${GREEN}✓ Todos os recursos foram limpos.${NC}"
fi

echo -e "${BLUE}==============================================${NC}"
EOF
chmod +x KindStop.sh

echo -e "\n${BLUE}===============================================${NC}"
echo -e "${GREEN}RESUMO DO CLUSTER KIND${NC}"
echo -e "${BLUE}===============================================${NC}"

echo -e "\n${YELLOW}Informações do Cluster:${NC}"
echo -e "  Nome do Cluster: ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "  API Server: ${GREEN}https://127.0.0.1:$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | cut -d ':' -f 3)${NC}"
echo -e "  Arquivo Kubeconfig: ${GREEN}$HOME/.kube/config${NC}"

echo -e "\n${YELLOW}Portas expostas:${NC}"
echo -e "  HTTP: ${GREEN}${HTTP_PORT}${NC} (Mapeada para porta 80 do cluster)"
echo -e "  HTTPS: ${GREEN}${HTTPS_PORT}${NC} (Mapeada para porta 443 do cluster)"
if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
    echo -e "  Registro local: ${GREEN}${REGISTRY_PORT}${NC} (Mapeada para porta 5000 do cluster)"
fi

echo -e "\n${YELLOW}Para verificar o status do cluster, execute: ${BLUE}./kind-status.sh${NC}"
echo -e "${YELLOW}Para interromper o cluster, execute: ${BLUE}./KindStop.sh ${CLUSTER_NAME}${NC}"

echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}Cluster KIND instalado e configurado!${NC}"
echo -e "${BLUE}=================================================${NC}\n"
kubectl get all -A
echo -e ""
echo -e ""
kubectl get nodes -o wide
echo -e ""
echo -e "${GREEN}Verificando IP do Ingress Controller (aguarde até 60s)...${NC}"
ATTEMPTS=0
MAX_ATTEMPTS=20
INGRESS_IP=""

while [ -z "$INGRESS_IP" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
  sleep 5
  INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  ATTEMPTS=$((ATTEMPTS+1))
  echo -e "${YELLOW}Tentativa $ATTEMPTS/$MAX_ATTEMPTS: IP atual do Ingress = ${INGRESS_IP:-N/A}${NC}"
done

if [ "$INGRESS_IP" = "${PUBLIC_IP}" ]; then
  echo -e "${GREEN}SUCESSO: Ingress Controller está usando o IP público ${PUBLIC_IP}.${NC}"
else
  echo -e "${RED}ERRO: Ingress Controller não atribuiu o IP ${PUBLIC_IP}. Verifique:${NC}"
  echo -e "${YELLOW}1. MetalLB está instalado/configurado?${NC}"
  echo -e "${YELLOW}2. O IP ${PUBLIC_IP} está no pool do MetalLB?${NC}"
  echo -e "${YELLOW}3. Regras de firewall da OCI permitem tráfego nas portas 80/443?${NC}"
  kubectl get svc -n ingress-nginx
  exit 1  # Encerra o script com erro
fi

if [[ "$CREATE_REGISTRY" =~ ^[Ss]$ ]]; then
        echo -e "\n${YELLOW}=== Registro Docker Local ===${NC}"
        echo -e "O registro Docker local está disponível em: ${GREEN}${PUBLIC_IP}:${REGISTRY_PORT}${NC}"
        echo -e "\n${BLUE}Para listar imagens no registro:${NC}"
        echo -e "  curl http://${PUBLIC_IP}:${REGISTRY_PORT}/v2/_catalog"
        echo -e "\n${BLUE}Para enviar uma imagem para o registro:${NC}"
        echo -e "  docker tag [sua-imagem:tag] ${PUBLIC_IP}:${REGISTRY_PORT}/[sua-imagem:tag]"
        echo -e "  docker push ${PUBLIC_IP}:${REGISTRY_PORT}/[sua-imagem:tag]"
        echo -e "\n${BLUE}Para buscar uma imagem do registro:${NC}"
        echo -e "  docker pull ${PUBLIC_IP}:${REGISTRY_PORT}/[sua-imagem:tag]"
        echo -e "\n${BLUE}Para usar imagens do registro no Kubernetes:${NC}"
        echo -e "  Adicione em seu YAML: image: ${PUBLIC_IP}:${REGISTRY_PORT}/[sua-imagem:tag]"
fi

echo -e "\n${YELLOW}Métricas e Autoscaling:${NC}"
echo -e "  Metrics Server: ${GREEN}Instalado${NC}"
echo -e "  Ver métricas dos nós: ${BLUE}kubectl top nodes${NC}"
echo -e "  Ver métricas dos pods: ${BLUE}kubectl top pods${NC}"
echo -e "  Criar um HPA: ${BLUE}kubectl autoscale deployment <nome> --cpu-percent=50 --min=1 --max=10${NC}"
echo -e "  Listar HPAs: ${BLUE}kubectl get hpa --all-namespaces${NC}"

echo -e "${GREEN}Verificando IP do Ingress Controller (aguarde até 60s)...${NC}"
ATTEMPTS=0
MAX_ATTEMPTS=20
INGRESS_IP=""

while [ -z "$INGRESS_IP" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
  sleep 5
  INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  ATTEMPTS=$((ATTEMPTS+1))
  echo -e "${YELLOW}Tentativa $ATTEMPTS/$MAX_ATTEMPTS: IP atual do Ingress = ${INGRESS_IP:-N/A}${NC}"
done

if [ "$INGRESS_IP" = "${PUBLIC_IP}" ]; then
  echo -e "${GREEN}SUCESSO: Ingress Controller está usando o IP público ${PUBLIC_IP}.${NC}"
else
  echo -e "${RED}ERRO: Ingress Controller não atribuiu o IP ${PUBLIC_IP}. Verifique:${NC}"
  echo -e "${YELLOW}1. MetalLB está instalado/configurado?${NC}"
  echo -e "${YELLOW}2. O IP ${PUBLIC_IP} está no pool do MetalLB?${NC}"
  echo -e "${YELLOW}3. Regras de firewall da OCI permitem tráfego nas portas 80/443?${NC}"
  kubectl get svc -n ingress-nginx
  exit 1
fi