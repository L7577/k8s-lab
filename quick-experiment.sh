#!/bin/bash
# =============================================================================
# quick-experiment.sh - 5 分钟快速 K8s 实验脚本
# =============================================================================
# 从零创建 Kind 集群、部署应用、运行核心测试，5 分钟内完成
#
# 用法:
#   ./quick-experiment.sh                # 默认版本快速实验
#   ./quick-experiment.sh v1.28.15       # 指定 K8s 版本
#   ./quick-experiment.sh v1.30.6 --keep # 保留集群供进一步探索
# =============================================================================

set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
title() { echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"; }
header(){ echo -e "${BOLD}$*${NC}"; }

# ─── 参数 ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="k8s-lab"
K8S_VERSION="v1.31.2"
KEEP_CLUSTER=false
START_TIME=$(date +%s)

# 使用 while 循环 + case 解析参数，支持任意参数顺序
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP_CLUSTER=true; shift ;;
        --help|-h)
            echo "用法: ./quick-experiment.sh [K8S_VERSION] [--keep]"
            echo ""
            echo "参数:"
            echo "  K8S_VERSION    指定 Kind 节点镜像版本 (默认: v1.31.2)"
            echo "  --keep         保留集群供进一步探索"
            echo ""
            echo "示例:"
            echo "  ./quick-experiment.sh                      # 默认版本"
            echo "  ./quick-experiment.sh v1.28.15             # 指定版本"
            echo "  ./quick-experiment.sh v1.30.6 --keep       # 保留集群"
            exit 0
            ;;
        --*) error "未知参数: $1"; exit 1 ;;
        *)
            K8S_VERSION="$1"
            [[ "$K8S_VERSION" != v* ]] && K8S_VERSION="v${K8S_VERSION}"
            shift
            ;;
    esac
done

# ─── 前置检查 ──────────────────────────────────────────────────────────────
preflight() {
    title
    header "🔍 前置检查"
    echo ""

    for cmd in docker kind kubectl; do
        if ! command -v $cmd &>/dev/null; then
            error "$cmd 未安装"
            echo "  请先执行安装:"
            echo "    sudo bash install-docker.sh --install"
            echo "    sudo bash install-kind.sh --install"
            echo "    sudo bash install-kubectl.sh --install"
            echo "    exec newgrp docker"
            exit 1
        fi
    done

    if ! docker info &>/dev/null; then
        error "Docker 未运行"
        exit 1
    fi

    ok "环境就绪"
}

# ─── 清理 ──────────────────────────────────────────────────────────────────
cleanup() {
    info "清理集群..."
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   🚀  k8s-lab 5 分钟快速实验                 ║${NC}"
    echo -e "${BOLD}║   K8s 版本: ${K8S_VERSION}                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"

    preflight
    cleanup

    # ─── 1. 创建集群 ──────────────────────────────────────────────────────
    title
    header "📦 1/5: 创建多节点 Kind 集群"
    echo ""

    info "创建 4 节点集群（1 控制平面 + 3 Worker）..."
    if [ "$K8S_VERSION" = "v1.31.2" ]; then
        kind create cluster --name "$CLUSTER_NAME" --config kind-cluster.yaml 2>&1
    else
        kind create cluster --name "$CLUSTER_NAME" \
            --image "kindest/node:${K8S_VERSION}" \
            --config kind-cluster.yaml 2>&1
    fi
    ok "集群创建成功"

    # ─── 2. 部署 Nginx ────────────────────────────────────────────────────
    title
    header "📦 2/5: 部署 Nginx 并暴露服务"
    echo ""

    # 预拉取镜像到宿主机，再加载到 Kind 节点（避免 Kind 容器内无法直连 Docker Hub）
    info "预加载 nginx:alpine 镜像到集群节点..."
    docker pull nginx:alpine 2>/dev/null || true
    kind load docker-image nginx:alpine --name "$CLUSTER_NAME" 2>/dev/null
    ok "镜像已加载"

    kubectl create deployment nginx --image=nginx:alpine --replicas=2
    kubectl expose deployment nginx --port=80 --type=NodePort
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=120s
    kubectl get pods -o wide
    ok "Nginx 部署完成（2 副本）"

    # ─── 3. 端口转发 + 访问验证 ───────────────────────────────────────────
    title
    header "🌐 3/5: 验证服务访问"
    echo ""

    kubectl port-forward service/nginx 8080:80 &
    local PF_PID=$!
    sleep 3

    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null | grep -q "200"; then
        ok "✅ Nginx 服务正常 (HTTP 200)"
    else
        warn "端口转发访问异常"
    fi
    kill "$PF_PID" 2>/dev/null || true

    # ─── 4. 核心测试 ──────────────────────────────────────────────────────
    title
    header "🧪 4/5: 核心功能测试"
    echo ""

    # 自愈测试
    info "自愈测试：删除一个 Pod..."
    POD=$(kubectl get pods -l app=nginx -o name | head -1)
    kubectl delete "$POD" --wait=false
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=30s
    ok "自愈成功"

    # 扩容测试
    echo ""
    info "扩容测试：2 → 5..."
    kubectl scale deployment nginx --replicas=5
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=30s
    kubectl get pods -o wide
    ok "扩容成功"

    # ─── 5. 汇总 ──────────────────────────────────────────────────────────
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    title
    header "🎉 实验完成！"
    echo ""
    echo -e "  ⏱️  耗时: ${BOLD}${DURATION} 秒${NC}"
    echo -e "  ☸️  集群: ${BOLD}${CLUSTER_NAME}${NC}"
    echo -e "  📊 节点:"
    kubectl get nodes -o wide
    echo ""
    echo -e "  📋 Pods:"
    kubectl get pods

    if [ "$KEEP_CLUSTER" = true ]; then
        echo ""
        echo -e "  ${GREEN}集群已保留，随时可用！${NC}"
        echo ""
        echo "  常用命令:"
        echo -e "    ${CYAN}kubectl get nodes${NC}"
        echo -e "    ${CYAN}kubectl get pods -A${NC}"
        echo -e "    ${CYAN}kubectl port-forward service/nginx 8080:80${NC}"
        echo -e "    ${CYAN}kind delete cluster --name ${CLUSTER_NAME}${NC}"
    else
        echo ""
        info "清理集群..."
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
        ok "集群已清理"
        echo ""
        echo -e "  ${GREEN}✅ 快速实验完成！${NC}"
        echo ""
    fi
}

main
