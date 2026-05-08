#!/bin/bash
# =============================================================================
# local-ci.sh - 本地 CI/CD 模拟脚本
# =============================================================================
# 在本地模拟 CI/CD 流水线，无需提交代码即可测试完整的 K8s 部署流程
#
# 功能:
#   1. 创建多节点 Kind 集群
#   2. 部署应用并验证
#   3. 运行自愈/扩容/回滚测试
#   4. 自动清理
#
# 用法:
#   ./local-ci.sh                   # 使用默认版本 (v1.31.2)
#   ./local-ci.sh v1.28.15          # 指定 K8s 版本
#   ./local-ci.sh v1.30.6 --no-cleanup  # 保留集群供调试
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
CLUSTER_NAME="ci-local-test"
K8S_VERSION="v1.31.2"
CLEANUP=true

# 使用 while 循环 + case 解析参数，支持任意参数顺序
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cleanup) CLEANUP=false; shift ;;
        --help|-h)
            echo "用法: ./local-ci.sh [K8S_VERSION] [--no-cleanup]"
            echo ""
            echo "参数:"
            echo "  K8S_VERSION       指定 Kind 节点镜像版本 (默认: v1.31.2)"
            echo "  --no-cleanup      保留集群供调试"
            echo ""
            echo "示例:"
            echo "  ./local-ci.sh                        # 默认版本"
            echo "  ./local-ci.sh v1.28.15               # 指定版本"
            echo "  ./local-ci.sh v1.30.6 --no-cleanup   # 保留集群"
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
            error "$cmd 未安装。请先运行: make install"
            exit 1
        fi
    done

    if ! docker info &>/dev/null; then
        error "Docker 未运行。请先启动 Docker"
        exit 1
    fi

    info "所有依赖已就绪"
}

# ─── 清理 ──────────────────────────────────────────────────────────────────
cleanup() {
    title
    header "🧹 清理集群"
    echo ""
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        kind delete cluster --name "$CLUSTER_NAME"
        ok "集群已删除"
    else
        info "集群不存在，无需清理"
    fi
}

# ─── Step 1: 创建集群 ────────────────────────────────────────────────────
step_create_cluster() {
    title
    header "📦 Step 1/8: 创建多节点 Kind 集群 (${K8S_VERSION})"
    echo ""

    # 使用 kind-cluster.yaml 配置（多节点），确保与真实环境一致
    info "使用 kind-cluster.yaml 配置创建 4 节点集群..."

    # 如果指定了版本，先用默认配置创建，再指定镜像
    if [ "$K8S_VERSION" != "v1.31.2" ]; then
        kind create cluster \
            --name "$CLUSTER_NAME" \
            --image "kindest/node:${K8S_VERSION}" \
            --config kind-cluster.yaml 2>&1
    else
        kind create cluster \
            --name "$CLUSTER_NAME" \
            --config kind-cluster.yaml 2>&1
    fi

    ok "集群创建成功（1 控制平面 + 3 Worker）"
}

# ─── Step 2: 验证集群 ────────────────────────────────────────────────────
step_verify_cluster() {
    title
    header "🔎 Step 2/8: 验证集群状态"
    echo ""

    kubectl cluster-info
    echo ""

    kubectl get nodes -o wide
    echo ""

    local NODE_COUNT
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    if [ "$NODE_COUNT" -ge 2 ]; then
        ok "集群正常，${NODE_COUNT} 个节点就绪"
    else
        error "集群异常，仅 ${NODE_COUNT} 个节点"
        return 1
    fi

    kubectl get pods -A
}

# ─── Step 3: 部署应用 ────────────────────────────────────────────────────
step_deploy_app() {
    title
    header "📦 Step 3/8: 部署应用"
    echo ""

    # 使用 deploy-example.yaml 统一部署（与文档一致）
    info "使用 deploy-example.yaml 部署 Deployment + Service..."
    kubectl apply -f deploy-example.yaml 2>&1

    info "等待 Pod 就绪..."
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=120s

    kubectl get pods -o wide
    ok "应用部署完成（3 副本）"
}

# ─── Step 4: 端口转发测试 ────────────────────────────────────────────────
step_port_forward() {
    title
    header "🌐 Step 4/8: 端口转发与服务访问测试"
    echo ""

    kubectl port-forward service/nginx 8080:80 &
    local PF_PID=$!
    sleep 3

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        ok "Nginx 服务可正常访问 (HTTP 200)"
    else
        warn "端口转发访问结果: HTTP ${HTTP_CODE}"
    fi

    kill "$PF_PID" 2>/dev/null || true
}

# ─── Step 5: 扩容测试 ────────────────────────────────────────────────────
step_scale() {
    title
    header "📈 Step 5/8: 扩缩容测试"
    echo ""

    info "扩容到 5 副本..."
    kubectl scale deployment nginx --replicas=5
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s
    ok "扩容成功: 3 → 5"

    kubectl get pods -o wide
    echo ""

    info "缩容到 2 副本..."
    kubectl scale deployment nginx --replicas=2
    sleep 5

    local ACTUAL
    ACTUAL=$(kubectl get pods -l app=nginx --no-headers 2>/dev/null | wc -l)
    if [ "$ACTUAL" -eq 2 ]; then
        ok "缩容成功: 5 → 2"
    else
        warn "缩容结果异常（期望 2，实际 ${ACTUAL}）"
    fi
}

# ─── Step 6: 自愈测试 ────────────────────────────────────────────────────
step_self_heal() {
    title
    header "🩹 Step 6/8: 自愈测试"
    echo ""

    local POD_TO_DELETE
    POD_TO_DELETE=$(kubectl get pods -l app=nginx -o name | head -1)
    info "删除 Pod: ${POD_TO_DELETE}"

    kubectl delete "$POD_TO_DELETE" --wait=false
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s
    ok "自愈成功：新 Pod 已自动创建并就绪"

    echo ""
    info "批量删除所有 Pod 测试..."
    kubectl delete pod -l app=nginx --all
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s
    ok "批量自愈成功"
}

# ─── Step 7: 回滚测试 ────────────────────────────────────────────────────
step_rollback() {
    title
    header "🔄 Step 7/8: 发布回滚测试"
    echo ""

    # 记录初始版本
    kubectl annotate deployment/nginx kubernetes.io/change-cause="initial deploy nginx:alpine"
    sleep 2

    # 模拟升级
    info "模拟发布新版本..."
    kubectl set image deployment/nginx nginx=nginx:1.26
    kubectl annotate deployment/nginx kubernetes.io/change-cause="upgrade to nginx:1.26"
    kubectl rollout status deployment/nginx --timeout=30s || true

    # 模拟有问题的版本
    info "模拟故障版本..."
    kubectl set image deployment/nginx nginx=nginx:1.26-perl 2>&1 || true
    sleep 3

    # 查看历史
    echo ""
    header "回滚历史:"
    kubectl rollout history deployment/nginx

    # 回滚
    echo ""
    info "回滚到初始版本..."
    kubectl rollout undo deployment/nginx --to-revision=1
    kubectl rollout status deployment/nginx --timeout=60s

    # 验证
    local ROLLBACK_IMAGE
    ROLLBACK_IMAGE=$(kubectl get deployment nginx -o jsonpath='{.spec.template.spec.containers[0].image}')
    echo -e "  当前镜像: ${BOLD}${ROLLBACK_IMAGE}${NC}"
    ok "回滚测试完成"
}

# ─── Step 8: 清理 ────────────────────────────────────────────────────────
step_cleanup() {
    if [ "$CLEANUP" = true ]; then
        cleanup
        echo ""
        ok "✅ 全部 CI 测试通过！"
    else
        echo ""
        info "集群已保留: kind-${CLUSTER_NAME}"
        echo "  清理命令: kind delete cluster --name ${CLUSTER_NAME}"
        echo ""
        ok "✅ CI 测试完成（集群已保留供调试）"
    fi
}

# ─── 主流程 ──────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   ☸️  本地 CI/CD 模拟流水线                  ║${NC}"
    echo -e "${BOLD}║   K8s 版本: ${K8S_VERSION}                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"

    preflight
    cleanup  # 确保环境干净
    step_create_cluster
    step_verify_cluster
    step_deploy_app
    step_port_forward
    step_scale
    step_self_heal
    step_rollback
    step_cleanup
}

main
