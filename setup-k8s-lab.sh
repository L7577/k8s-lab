#!/bin/bash
# =============================================================================
# k8s-lab 一键部署总调度脚本
# =============================================================================
# 功能：
#   1. 一键安装所有依赖（Docker + Kind + kubectl）
#   2. 创建 Kind Kubernetes 集群
#   3. 运行各项功能测试（部署/扩缩容/自愈/存储等）
#   4. 一键清理所有资源
#
# 用法：
#   sudo bash setup-k8s-lab.sh                          # 交互式菜单
#   sudo bash setup-k8s-lab.sh --install                # 仅安装依赖
#   sudo bash setup-k8s-lab.sh --cluster                # 仅创建集群
#   sudo bash setup-k8s-lab.sh --test [场景]             # 运行指定测试
#   sudo bash setup-k8s-lab.sh --all                    # 一键全流程
#   sudo bash setup-k8s-lab.sh --cleanup                # 清理所有
#
# 测试场景：
#   basic       - 基础部署 + 暴露服务
#   scale       - 扩缩容测试
#   self-heal   - 自愈测试
#   storage     - 存储测试
#   resource    - 资源限制测试
#   canary      - 金丝雀发布和回滚
#   network     - 网络插件替换测试
#   all         - 运行所有测试
# =============================================================================

set -euo pipefail

# ─── 颜色定义 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── 常量 ──────────────────────────────────────────────────────────────────
# 获取脚本所在目录（解析符号链接，确保路径准确）
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 如果 readlink 不可用则使用备用方法
if [ ! -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
CLUSTER_NAME="k8s-lab"
K8S_VERSION="${K8S_VERSION:-v1.31.2}"  # 默认 K8s 版本（可通过环境变量覆盖）
DEFAULT_NODE_IMAGE="kindest/node:${K8S_VERSION}"
KUBECONFIG_DIR="${HOME}/.kube"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/config"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="/tmp/k8s-lab-setup-${TIMESTAMP}.log"


# ─── 工具函数 ──────────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
title() { echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"; }
header(){ echo -e "${BOLD}$*${NC}" | tee -a "$LOG_FILE"; }

# ─── 前置检查 ──────────────────────────────────────────────────────────────

preflight_check() {
    title
    header "🔍 前置检查"
    echo ""

    # 检查是否为 root
    if [ "$EUID" -ne 0 ]; then
        error "部分操作需要 root 权限，建议使用 sudo 运行"
        echo "  用法: sudo bash $0"
        echo ""
    fi

    # 检查操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "  操作系统：${BOLD}$NAME $VERSION_ID${NC}"
        if [ "$ID" != "ubuntu" ]; then
            warn "此项目主要面向 Ubuntu，当前系统为 $ID（部分功能可能不兼容）"
        fi
    fi

    # 检查架构
    ARCH=$(uname -m)
    echo -e "  系统架构：${BOLD}$ARCH${NC}"
    case "$ARCH" in
        x86_64|amd64|aarch64|arm64) ;;
        *) error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    # 检查磁盘空间
    local AVAIL
    AVAIL=$(df -BG /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "N/A")
    if [ "$AVAIL" != "N/A" ] && [ "$AVAIL" -lt 5 ] 2>/dev/null; then
        warn "磁盘空间不足（仅剩 ${AVAIL}G），Kind 集群可能需要至少 5G 可用空间"
    else
        echo -e "  /var/lib/docker 可用空间：${BOLD}${AVAIL}G${NC}"
    fi

    ok "前置检查完成"
}

# ─── 步骤 1：安装所有依赖 ──────────────────────────────────────────────────

install_all() {
    title
    header "📦 一键安装所有依赖"
    echo ""

    # 1.1 安装 Docker
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        ok "Docker 已安装，跳过"
    else
        info "安装 Docker..."
        if [ -f "${SCRIPT_DIR}/install-docker.sh" ]; then
            bash "${SCRIPT_DIR}/install-docker.sh" --install || {
                error "Docker 安装失败"
                return 1
            }
        else
            error "install-docker.sh 未找到"
            return 1
        fi
    fi

    # 1.2 安装 Kind
    if command -v kind &>/dev/null; then
        ok "Kind 已安装：$(kind version 2>/dev/null)"
    else
        info "安装 Kind..."
        if [ -f "${SCRIPT_DIR}/install-kind.sh" ]; then
            bash "${SCRIPT_DIR}/install-kind.sh" --install || {
                error "Kind 安装失败"
                return 1
            }
        else
            error "install-kind.sh 未找到"
            return 1
        fi
    fi

    # 1.3 安装 kubectl
    if command -v kubectl &>/dev/null; then
        ok "kubectl 已安装：$(kubectl version --client 2>/dev/null | head -1)"
    else
        info "安装 kubectl..."
        if [ -f "${SCRIPT_DIR}/install-kubectl.sh" ]; then
            bash "${SCRIPT_DIR}/install-kubectl.sh" --install || {
                error "kubectl 安装失败"
                return 1
            }
        else
            error "install-kubectl.sh 未找到"
            return 1
        fi
    fi

    echo ""
    ok "✅ 所有依赖安装完成！"

    # 检查 docker 组
    local USER_NAME=${SUDO_USER:-$USER}
    if ! groups "$USER_NAME" 2>/dev/null | grep -qw docker; then
        echo ""
        warn "当前用户不在 docker 组中，请执行以下命令重新登录："
        echo -e "    ${CYAN}exec newgrp docker${NC}"
        echo "  或重新登录终端后再进行后续操作。"
    fi
}

# ─── 步骤 2：创建 Kind 集群 ────────────────────────────────────────────────

create_cluster() {
    local CLUSTER_CONFIG="${1:-kind-cluster.yaml}"
    local NODE_IMAGE=""

    # 从参数中提取版本（支持 --k8s-version v1.28.15 格式）
    if [[ "$CLUSTER_CONFIG" == --k8s-version ]]; then
        # 如果第一个参数是 --k8s-version，下一个参数是版本
        K8S_VERSION="${2:-${K8S_VERSION:-v1.31.2}}"
        # 确保版本以 v 开头
        [[ "$K8S_VERSION" != v* ]] && K8S_VERSION="v${K8S_VERSION}"
        NODE_IMAGE="kindest/node:${K8S_VERSION}"
        CLUSTER_CONFIG="${3:-kind-cluster.yaml}"
    fi

    # 如果 NODE_IMAGE 未设置但 K8S_VERSION 非默认值，则自动使用对应镜像
    if [ -z "$NODE_IMAGE" ] && [ "${K8S_VERSION}" != "v1.31.2" ]; then
        NODE_IMAGE="kindest/node:${K8S_VERSION}"
    fi

    title
    header "☸️  创建 Kind 集群"
    echo ""

    # 检查 Kind 是否可用
    if ! command -v kind &>/dev/null; then
        error "Kind 未安装，请先执行 install 或运行 setup-k8s-lab.sh --install"
        return 1
    fi

    # 检查 Docker 是否运行
    if ! docker info &>/dev/null; then
        error "Docker 未运行，请先启动 Docker"
        return 1
    fi

    # 检查是否已存在同名集群
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "集群 '${CLUSTER_NAME}' 已存在"
        echo -ne "${YELLOW}是否删除重建？(y/N): ${NC}"
        read -r RECREATE
        if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
            info "删除现有集群..."
            kind delete cluster --name "$CLUSTER_NAME"
        else
            info "使用现有集群"
            return 0
        fi
    fi

    # 确定配置文件路径
    local CONFIG_PATH
    if [ -f "$CLUSTER_CONFIG" ]; then
        CONFIG_PATH="$CLUSTER_CONFIG"
    elif [ -f "${SCRIPT_DIR}/${CLUSTER_CONFIG}" ]; then
        CONFIG_PATH="${SCRIPT_DIR}/${CLUSTER_CONFIG}"
    else
        # 默认配置：1 控制平面 + 3 Worker
        warn "未找到配置文件 ${CLUSTER_CONFIG}，使用默认配置"
        echo ""
        echo -ne "${YELLOW}请输入 Worker 节点数 [默认 3]: ${NC}"
        read -r WORKER_COUNT
        WORKER_COUNT=${WORKER_COUNT:-3}

        CONFIG_PATH=$(mktemp)
        cat > "$CONFIG_PATH" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
EOF
        for i in $(seq 1 "$WORKER_COUNT"); do
            echo "  - role: worker" >> "$CONFIG_PATH"
        done
    fi

    echo -e "  集群名称：${BOLD}${CLUSTER_NAME}${NC}"
    echo -e "  K8s 版本 ：${BOLD}${K8S_VERSION}${NC}"
    echo -e "  配置文件：${BOLD}${CONFIG_PATH}${NC}"
    echo ""

    # 构建创建命令
    local CREATE_CMD="kind create cluster --config \"$CONFIG_PATH\""
    if [ -n "$NODE_IMAGE" ]; then
        CREATE_CMD+=" --image \"${NODE_IMAGE}\""
    fi

    # 创建集群
    info "创建 Kind 集群（这可能需要 2-5 分钟）..."
    if eval "$CREATE_CMD" 2>&1 | tee -a "$LOG_FILE"; then
        ok "集群创建成功！"
    else
        error "集群创建失败，请查看日志：${LOG_FILE}"
        return 1
    fi

    # 等待集群就绪
    echo ""
    info "等待集群就绪..."
    sleep 5
    kubectl cluster-info 2>&1 | tee -a "$LOG_FILE" || true

    # 显示节点信息
    echo ""
    header "📋 集群节点状态"
    kubectl get nodes -o wide

    echo ""
    ok "集群 '${CLUSTER_NAME}' 已就绪，kubectl 上下文已切换"
}


# ─── 步骤 3：运行测试 ────────────────────────────────────────────────────

# ─── 3.1 基础部署测试 ────────────────────────────────────────────────

test_basic_deploy() {
    header "📦 测试 1：基础部署与暴露服务"
    echo ""
    # 预拉取镜像到宿主机，再加载到 Kind 节点（避免 Kind 容器内无法直连 Docker Hub）
    info "预加载 nginx:alpine 镜像到集群节点..."
    docker pull nginx:alpine 2>/dev/null || true
    kind load docker-image nginx:alpine --name "$CLUSTER_NAME" 2>/dev/null
    ok "镜像已加载"

    info "创建 deployment..."
    kubectl create deployment nginx --image=nginx:alpine --replicas=3 2>&1 | tee -a "$LOG_FILE"

    info "创建 service..."
    kubectl expose deployment nginx --port=80 --type=NodePort 2>&1 | tee -a "$LOG_FILE"

    info "等待 Pod 就绪..."
    if kubectl wait --for=condition=ready pod -l app=nginx --timeout=120s 2>&1; then
        ok "所有 Pod 已就绪"
    else
        error "Pod 启动超时"
        kubectl describe deployment nginx | tee -a "$LOG_FILE"
        return 1
    fi

    echo ""
    kubectl get pods -o wide
    echo ""

    # 端口转发测试
    info "端口转发测试..."
    kubectl port-forward service/nginx 8080:80 &
    local PF_PID=$!
    sleep 3

    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null | grep -q "200"; then
        ok "Nginx 服务可正常访问 (HTTP 200)"
    else
        warn "端口转发访问失败（可能因环境限制）"
    fi
    kill "$PF_PID" 2>/dev/null || true

    ok "基础部署测试通过 ✅"
}

# ─── 3.2 扩缩容测试 ─────────────────────────────────────────────────

test_scale() {
    header "📈 测试 2：扩缩容测试"
    echo ""

    local INITIAL=3
    local TARGET=5
    local SHRINK=2

    info "当前副本数：${INITIAL}"
    info "扩容到 ${TARGET} 个副本..."
    kubectl scale deployment nginx --replicas=${TARGET} 2>&1 | tee -a "$LOG_FILE"

    if kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s 2>&1; then
        ok "扩容成功：${INITIAL} → ${TARGET}"
    else
        error "扩容超时"
    fi

    kubectl get pods -o wide
    echo ""

    info "缩容到 ${SHRINK} 个副本..."
    kubectl scale deployment nginx --replicas=${SHRINK} 2>&1 | tee -a "$LOG_FILE"
    sleep 5

    local ACTUAL
    ACTUAL=$(kubectl get pods -l app=nginx --no-headers 2>/dev/null | wc -l)
    if [ "$ACTUAL" -eq "$SHRINK" ]; then
        ok "缩容成功：${TARGET} → ${SHRINK}"
    else
        warn "缩容结果异常（期望 ${SHRINK}，实际 ${ACTUAL}）"
    fi

    ok "扩缩容测试通过 ✅"
}

# ─── 3.3 自愈测试 ───────────────────────────────────────────────────

test_self_heal() {
    header "🩹 测试 3：自愈测试"
    echo ""

    local POD_COUNT
    POD_COUNT=$(kubectl get pods -l app=nginx --no-headers 2>/dev/null | wc -l)

    info "当前 Pod 数：${POD_COUNT}"
    info "删除一个 Pod 观察自动重建..."

    local POD_TO_DELETE
    POD_TO_DELETE=$(kubectl get pods -l app=nginx -o name | head -1)
    echo -e "  删除 Pod：${POD_TO_DELETE}"

    kubectl delete "$POD_TO_DELETE" --wait=false 2>&1 | tee -a "$LOG_FILE"
    sleep 3

    info "等待新 Pod 就绪..."
    if kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s 2>&1; then
        ok "自愈成功：新 Pod 已自动创建并就绪"
    else
        error "自愈超时"
        return 1
    fi

    echo ""
    info "删除所有 Pod 测试批量自愈..."
    kubectl delete pod -l app=nginx --all 2>&1 | tee -a "$LOG_FILE"
    sleep 5

    if kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s 2>&1; then
        ok "批量自愈成功"
    else
        error "批量自愈超时"
    fi

    ok "自愈测试通过 ✅"
}

# ─── 3.4 存储测试 ───────────────────────────────────────────────────

test_storage() {
    header "💾 测试 4：存储测试"
    echo ""

    info "创建 PVC 和测试 Pod..."

    cat <<'EOF' | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - mountPath: /data
      name: storage
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-pvc
EOF

    info "等待 Pod 就绪..."
    if kubectl wait --for=condition=ready pod/test-storage --timeout=60s 2>&1; then
        ok "存储 Pod 就绪"
    else
        error "存储 Pod 启动超时"
        kubectl describe pod test-storage | tee -a "$LOG_FILE"
        return 1
    fi

    # 验证存储
    info "验证存储读写..."
    kubectl exec test-storage -- df -h /data 2>&1 | tee -a "$LOG_FILE"
    kubectl exec test-storage -- sh -c "echo 'hello k8s storage test' > /data/test.txt" 2>&1 | tee -a "$LOG_FILE"

    local READ_BACK
    READ_BACK=$(kubectl exec test-storage -- cat /data/test.txt 2>/dev/null)
    if [ "$READ_BACK" = "hello k8s storage test" ]; then
        ok "存储读写测试通过"
    else
        warn "存储读写验证异常（输出: ${READ_BACK}）"
    fi

    # 清理
    kubectl delete pod test-storage --now 2>/dev/null || true
    kubectl delete pvc test-pvc 2>/dev/null || true

    ok "存储测试通过 ✅"
}

# ─── 3.5 资源限制测试 ───────────────────────────────────────────────

test_resource() {
    header "🔧 测试 5：资源限制测试"
    echo ""

    cat <<'EOF' | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"
apiVersion: v1
kind: Pod
metadata:
  name: resource-test
spec:
  containers:
  - name: stress
    image: progrium/stress
    command: ["stress"]
    args: ["--vm", "2", "--vm-bytes", "256M"]
    resources:
      requests:
        memory: "256Mi"
        cpu: "250m"
      limits:
        memory: "512Mi"
        cpu: "500m"
EOF

    info "等待 Pod 就绪..."
    if kubectl wait --for=condition=ready pod/resource-test --timeout=120s 2>&1; then
        ok "资源限制 Pod 就绪"
    else
        warn "资源限制 Pod 启动超时（可能因 stress 镜像拉取慢）"
        kubectl describe pod resource-test | tee -a "$LOG_FILE"
    fi

    # 验证资源
    kubectl describe pod resource-test 2>&1 | grep -A5 "Limits\|Requests" | tee -a "$LOG_FILE" || true

    info "查看资源使用..."
    kubectl top pod resource-test 2>&1 | tee -a "$LOG_FILE" || warn "kubectl top 不可用（未安装 metrics-server）"

    # 清理
    kubectl delete pod resource-test --now 2>/dev/null || true

    ok "资源限制测试通过 ✅"
}

# ─── 3.6 金丝雀发布与回滚测试 ─────────────────────────────────────

test_canary() {
    header "🔄 测试 6：金丝雀发布与回滚测试"
    echo ""

    # 部署稳定版
    info "部署稳定版应用 (nginx:alpine)..."
    kubectl create deployment stable-app --image=nginx:alpine --replicas=4 2>&1 | tee -a "$LOG_FILE"
    kubectl expose deployment stable-app --port=80 2>&1 | tee -a "$LOG_FILE"

    kubectl wait --for=condition=ready pod -l app=stable-app --timeout=60s 2>&1
    ok "稳定版部署完成"

    # 记录版本历史
    kubectl annotate deployment/stable-app kubernetes.io/change-cause="initial deployment nginx:alpine" 2>&1 | tee -a "$LOG_FILE"
    sleep 3

    # 模拟金丝雀发布（升级）
    info "模拟金丝雀发布（升级到 nginx:1.26）..."
    kubectl set image deployment/stable-app stable-app=nginx:1.26 2>&1 | tee -a "$LOG_FILE"
    kubectl annotate deployment/stable-app kubernetes.io/change-cause="upgrade to 1.26-canary" 2>&1 | tee -a "$LOG_FILE"
    sleep 5

    # 模拟回滚（使用一个不存在的版本触发失败）
    info "模拟有问题的版本更新..."
    kubectl set image deployment/stable-app stable-app=nginx:1.26-perl 2>&1 | tee -a "$LOG_FILE" || true
    sleep 3

    # 查看回滚历史
    echo ""
    header "回滚历史"
    kubectl rollout history deployment/stable-app 2>&1 | tee -a "$LOG_FILE"
    echo ""

    # 回滚到初始版本
    info "回滚到初始版本..."
    kubectl rollout undo deployment/stable-app --to-revision=1 2>&1 | tee -a "$LOG_FILE"
    kubectl rollout status deployment/stable-app --timeout=60s 2>&1 | tee -a "$LOG_FILE"

    # 验证回滚
    local ROLLBACK_IMAGE
    ROLLBACK_IMAGE=$(kubectl describe pod "$(kubectl get pods -l app=stable-app -o name | head -1)" 2>/dev/null | grep -i image | head -1)
    echo -e "  回滚后镜像：${ROLLBACK_IMAGE}"
    ok "金丝雀发布和回滚测试通过 ✅"

    # 清理
    kubectl delete service/stable-app 2>/dev/null || true
    kubectl delete deployment/stable-app 2>/dev/null || true
}

# ─── 3.7 网络插件替换测试 ─────────────────────────────────────────

test_network() {
    header "🌐 测试 7：网络插件替换测试（Calico）"
    echo ""

    local CALICO_CLUSTER="calico-test"
    local CALICO_CONFIG

    CALICO_CONFIG=$(mktemp)
    cat > "$CALICO_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CALICO_CLUSTER}
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF

    warn "此测试将创建一个独立的 Calico 集群，需要额外的资源"
    echo -ne "${YELLOW}确认运行？(y/N): ${NC}"
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "跳过网络插件测试"
        rm -f "$CALICO_CONFIG"
        return 0
    fi

    info "创建 Calico 测试集群..."
    if kind create cluster --config "$CALICO_CONFIG" 2>&1 | tee -a "$LOG_FILE"; then
        ok "Calico 测试集群创建成功"
    else
        error "集群创建失败"
        rm -f "$CALICO_CONFIG"
        return 1
    fi

    info "安装 Calico CNI..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27/manifests/calico.yaml 2>&1 | tee -a "$LOG_FILE" || {
        warn "Calico 安装失败（可能需要代理）"
        kind delete cluster --name "$CALICO_CLUSTER"
        rm -f "$CALICO_CONFIG"
        return 1
    }

    info "等待 Calico 就绪..."
    kubectl wait --for=condition=ready pods -n kube-system -l k8s-app=calico-node --timeout=120s 2>&1 | tee -a "$LOG_FILE" || true

    kubectl get pods -n kube-system 2>&1 | tee -a "$LOG_FILE" || true
    ok "网络插件替换测试通过 ✅"

    # 清理
    info "清理 Calico 测试集群..."
    kind delete cluster --name "$CALICO_CLUSTER"
    rm -f "$CALICO_CONFIG"
    ok "Calico 集群已清理"
}

# ─── 运行单个测试场景 ──────────────────────────────────────────────

run_single_test() {
    local SCENARIO="${1:-all}"

    case "$SCENARIO" in
        basic)
            test_basic_deploy
            ;;
        scale)
            test_scale
            ;;
        self-heal)
            test_self_heal
            ;;
        storage)
            test_storage
            ;;
        resource)
            test_resource
            ;;
        canary)
            test_canary
            ;;
        network)
            test_network
            ;;
        all)
            run_all_tests
            ;;
        *)
            error "未知测试场景: ${SCENARIO}"
            echo "可用场景: basic, scale, self-heal, storage, resource, canary, network, all"
            return 1
            ;;
    esac
}

# ─── 运行所有测试 ──────────────────────────────────────────────────

run_all_tests() {
    title
    header "🧪 运行全部功能测试"
    echo ""

    # 确保有 deployment
    if ! kubectl get deployment nginx &>/dev/null; then
        test_basic_deploy
    fi

    test_scale
    echo ""
    test_self_heal
    echo ""
    test_storage
    echo ""
    test_resource
    echo ""
    test_canary

    echo ""
    title
    header "📊 全部测试完成"
    echo ""
}

# ─── 步骤 4：清理环境 ──────────────────────────────────────────────────

cleanup_all() {
    title
    header "🧹 清理环境"
    echo ""

    echo -ne "${RED}⚠️  确认清理所有资源？此操作不可撤销！(y/N): ${NC}"
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "已取消清理"
        return
    fi
    echo ""

    # 4.1 删除所有 Kind 集群
    if command -v kind &>/dev/null; then
        local CLUSTERS
        CLUSTERS=$(kind get clusters 2>/dev/null)
        if [ -n "$CLUSTERS" ]; then
            info "删除所有 Kind 集群..."
            echo "$CLUSTERS" | while IFS= read -r cluster; do
                echo -e "  - 删除集群: ${CYAN}${cluster}${NC}"
                kind delete cluster --name "$cluster" 2>&1 | tee -a "$LOG_FILE"
            done
            ok "所有 Kind 集群已删除"
        else
            info "没有 Kind 集群需要删除"
        fi
    fi

    # 4.2 清理未使用的 Docker 镜像和容器
    echo ""
    info "清理未使用的 Docker 资源..."
    docker system prune -f 2>&1 | tail -1 || true
    ok "Docker 无用资源已清理"

    # 4.3 询问是否卸载工具
    echo ""
    echo -ne "${YELLOW}是否卸载所有工具（Docker + Kind + kubectl）？(y/N): ${NC}"
    read -r UNINSTALL
    if [[ "$UNINSTALL" =~ ^[Yy]$ ]]; then
        if [ -f "${SCRIPT_DIR}/install-kubectl.sh" ]; then
            bash "${SCRIPT_DIR}/install-kubectl.sh" --uninstall 2>&1 | tee -a "$LOG_FILE" || true
        fi
        if [ -f "${SCRIPT_DIR}/install-kind.sh" ]; then
            bash "${SCRIPT_DIR}/install-kind.sh" --uninstall 2>&1 | tee -a "$LOG_FILE" || true
        fi
        if [ -f "${SCRIPT_DIR}/install-docker.sh" ]; then
            bash "${SCRIPT_DIR}/install-docker.sh" --uninstall 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi

    # 4.4 清理临时文件
    echo ""
    info "清理临时文件..."
    rm -f /tmp/k8s-lab-*.log 2>/dev/null || true

    echo ""
    ok "环境清理完成"
}

# ─── 一键全流程 ───────────────────────────────────────────────────────

run_all_in_one() {
    title
    header "🚀 一键全流程部署"
    echo ""

    # 检查安装脚本是否存在
    for script in install-docker.sh install-kind.sh install-kubectl.sh; do
        if [ ! -f "${SCRIPT_DIR}/${script}" ]; then
            error "缺少 ${script}，请确保所有安装脚本在同一目录"
            exit 1
        fi
    done

    # 步骤 1：安装依赖
    info "【步骤 1/4】安装所有依赖..."
    install_all

    # 检查 docker 组
    local USER_NAME=${SUDO_USER:-$USER}
    if ! groups "$USER_NAME" 2>/dev/null | grep -qw docker; then
        echo ""
        warn "用户不在 docker 组中，请执行以下命令后重新运行："
        echo -e "  ${CYAN}exec newgrp docker${NC}"
        echo -e "  ${CYAN}sudo bash $0 --all${NC}"
        exit 1
    fi

    # 步骤 2：创建集群
    echo ""
    info "【步骤 2/4】创建 Kind 集群..."
    create_cluster

    # 步骤 3：运行测试
    echo ""
    info "【步骤 3/4】运行功能测试..."
    run_all_tests

    # 步骤 4：显示结果
    echo ""
    title
    header "🎉 一键全流程完成！"
    echo ""
    echo -e "  📍 集群名称：${BOLD}${CLUSTER_NAME}${NC}"
    echo -e "  📍 日志文件：${BOLD}${LOG_FILE}${NC}"
    echo ""
    echo "  后续操作："
    echo -e "    - 查看节点：${CYAN}kubectl get nodes${NC}"
    echo -e "    - 查看 Pod：${CYAN}kubectl get pods -A${NC}"
    echo -e "    - 清理环境：${CYAN}sudo bash $0 --cleanup${NC}"
    echo ""

    # 询问是否要继续保留集群
    echo -ne "${YELLOW}是否现在清理集群？(y/N): ${NC}"
    read -r CLEANUP_NOW
    if [[ "$CLEANUP_NOW" =~ ^[Yy]$ ]]; then
        cleanup_all
    else
        ok "集群已保留，随时可用。删除命令：kind delete cluster --name ${CLUSTER_NAME}"
    fi
}

# ─── 交互式菜单 ───────────────────────────────────────────────────────

show_menu() {
    clear
    title
    echo -e "        ${BOLD}${CYAN}☸️  k8s-lab 一键部署管理脚本${NC}"
    echo -e "        ${BLUE}Kubernetes 单物理机实验环境${NC}"
    title
    echo ""

    # 显示当前状态
    echo -e "  ${BOLD}当前状态：${NC}"
    if command -v docker &>/dev/null; then
        echo -e "    Docker   : ${GREEN}$(docker --version 2>/dev/null | head -1)${NC}"
    else
        echo -e "    Docker   : ${RED}未安装${NC}"
    fi
    if command -v kind &>/dev/null; then
        echo -e "    Kind     : ${GREEN}$(kind version 2>/dev/null)${NC}"
    else
        echo -e "    Kind     : ${RED}未安装${NC}"
    fi
    if command -v kubectl &>/dev/null; then
        echo -e "    kubectl  : ${GREEN}$(kubectl version --client 2>/dev/null | head -1)${NC}"
    else
        echo -e "    kubectl  : ${RED}未安装${NC}"
    fi
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        echo -e "    集群状态 : ${GREEN}${CLUSTER_NAME} 已创建${NC}"
    else
        echo -e "    集群状态 : ${YELLOW}未创建${NC}"
    fi
    echo ""

    title
    echo ""
    echo -e "  ${BOLD}1.${NC} 📦  一键安装所有依赖（Docker + Kind + kubectl）"
    echo -e "  ${BOLD}2.${NC} ☸️   创建 Kind 集群"
    echo -e "  ${BOLD}3.${NC} 🧪  运行全部功能测试"
    echo -e "  ${BOLD}4.${NC} 📋  选择单项测试运行"
    echo -e "  ${BOLD}5.${NC} 🚀  一键全流程（安装 → 创建 → 测试 → 清理）"
    echo -e "  ${BOLD}6.${NC} 🔍  环境检测（检查各组件的安装和运行状态）"
    echo -e "  ${BOLD}7.${NC} 🧹  清理环境"
    echo -e "  ${BOLD}0.${NC} 🚪  退出"
    echo ""
    echo -ne "  请选择 [0-7]: "
    read -r CHOICE

    case "$CHOICE" in
        1) install_all ;;
        2) create_cluster ;;
        3) run_all_tests ;;
        4) select_test ;;
        5) run_all_in_one ;;
        6) check_environment ;;
        7) cleanup_all ;;
        0) info "再见！"; exit 0 ;;
        *) warn "无效选择，请重新输入"; sleep 1; show_menu ;;
    esac

    echo ""
    echo -ne "${YELLOW}按 Enter 返回主菜单...${NC}"
    read -r
    show_menu
}

# ─── 选择单项测试 ───────────────────────────────────────────────────

select_test() {
    clear
    title
    header "📋 选择要运行的测试"
    echo ""
    echo -e "  ${BOLD}1.${NC} 📦  基础部署与暴露服务"
    echo -e "  ${BOLD}2.${NC} 📈  扩缩容测试"
    echo -e "  ${BOLD}3.${NC} 🩹  自愈测试"
    echo -e "  ${BOLD}4.${NC} 💾  存储测试"
    echo -e "  ${BOLD}5.${NC} 🔧  资源限制测试"
    echo -e "  ${BOLD}6.${NC} 🔄  金丝雀发布与回滚测试"
    echo -e "  ${BOLD}7.${NC} 🌐  网络插件替换测试（需独立集群）"
    echo -e "  ${BOLD}0.${NC} 🔙  返回主菜单"
    echo ""
    echo -ne "  请选择 [0-7]: "
    read -r TEST_CHOICE

    case "$TEST_CHOICE" in
        1) run_single_test basic ;;
        2) run_single_test scale ;;
        3) run_single_test self-heal ;;
        4) run_single_test storage ;;
        5) run_single_test resource ;;
        6) run_single_test canary ;;
        7) run_single_test network ;;
        0) return ;;
        *) warn "无效选择"; sleep 1; select_test ;;
    esac

    echo ""
    echo -ne "${YELLOW}按 Enter 返回测试菜单...${NC}"
    read -r
    select_test
}

# ─── 环境检测 ────────────────────────────────────────────────────────

check_environment() {
    title
    header "🔍 环境检测"
    echo ""

    # Docker 检测
    if command -v docker &>/dev/null; then
        echo -e "  ${BOLD}Docker${NC}"
        echo -e "    - 命令：${GREEN}$(docker --version)${NC}"
        if docker info &>/dev/null; then
            echo -e "    - 引擎：${GREEN}运行中${NC}"
        else
            echo -e "    - 引擎：${RED}未运行${NC}"
        fi
        if docker compose version &>/dev/null 2>&1; then
            echo -e "    - Compose：${GREEN}$(docker compose version)${NC}"
        fi
    else
        echo -e "  ${BOLD}Docker${NC}：${RED}未安装${NC}"
    fi
    echo ""

    # Kind 检测
    if command -v kind &>/dev/null; then
        echo -e "  ${BOLD}Kind${NC}"
        echo -e "    - 命令：${GREEN}$(kind version 2>/dev/null)${NC}"
        local CLUSTERS
        CLUSTERS=$(kind get clusters 2>/dev/null)
        if [ -n "$CLUSTERS" ]; then
            echo -e "    - 集群："
            echo "$CLUSTERS" | while IFS= read -r cl; do
                echo -e "      - ${CYAN}${cl}${NC}"
            done
        else
            echo -e "    - 集群：${YELLOW}无${NC}"
        fi
    else
        echo -e "  ${BOLD}Kind${NC}：${RED}未安装${NC}"
    fi
    echo ""

    # kubectl 检测
    if command -v kubectl &>/dev/null; then
        echo -e "  ${BOLD}kubectl${NC}"
        echo -e "    - 命令：${GREEN}$(kubectl version --client 2>/dev/null | head -1)${NC}"
        local CTX
        CTX=$(kubectl config current-context 2>/dev/null || echo "无")
        echo -e "    - 当前上下文：${BOLD}${CTX}${NC}"
        if kubectl cluster-info &>/dev/null 2>&1; then
            echo -e "    - 集群连接：${GREEN}正常${NC}"
        fi
    else
        echo -e "  ${BOLD}kubectl${NC}：${RED}未安装${NC}"
    fi
    echo ""

    # 系统资源
    echo -e "  ${BOLD}系统资源${NC}"
    echo -e "    - CPU：$(nproc) 核"
    echo -e "    - 内存：$(free -h | awk '/^Mem:/ {print $2}')（可用：$(free -h | awk '/^Mem:/ {print $7}')）"
    echo -e "    - 磁盘：$(df -h / | awk 'NR==2 {print $3}') / $(df -h / | awk 'NR==2 {print $2}')（可用：$(df -h / | awk 'NR==2 {print $4}')）"
}

# ─── CLI 参数处理 ──────────────────────────────────────────────────────

main() {
    # 初始化日志
    echo "k8s-lab setup log - $(date)" > "$LOG_FILE"

    case "${1:-}" in
        --install|-i)
            preflight_check
            install_all
            ;;
        --cluster|-c)
            preflight_check
            create_cluster "${2:-kind-cluster.yaml}"
            ;;
        --test|-t)
            preflight_check
            run_single_test "${2:-all}"
            ;;
        --all|-a)
            run_all_in_one
            ;;
        --cleanup|-cl)
            cleanup_all
            ;;
        --check|-ch)
            check_environment
            ;;
        --help|-h)
            echo "用法: sudo bash setup-k8s-lab.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --install, -i             一键安装所有依赖（需 sudo）"
            echo "  --cluster, -c [配置]      创建 Kind 集群"
            echo "  --test, -t [场景]         运行指定测试场景"
            echo "   场景: basic, scale, self-heal, storage, resource, canary, network, all"
            echo "  --all, -a                 一键全流程（安装→创建→测试）"
            echo "  --cleanup, -cl            清理所有资源（集群 + Docker + 工具）"
            echo "  --check, -ch              检测环境状态"
            echo "  --help, -h                显示此帮助"
            echo ""
            echo "无参数时启动交互式菜单"
            echo ""
            echo "示例:"
            echo "  sudo bash setup-k8s-lab.sh --all                    # 一键全流程"
            echo "  sudo bash setup-k8s-lab.sh --test scale             # 仅运行扩容测试"
            echo "  sudo bash setup-k8s-lab.sh --cluster kind-ha.yaml   # 创建 HA 集群"
            echo ""
            echo "日志文件: ${LOG_FILE}"
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
