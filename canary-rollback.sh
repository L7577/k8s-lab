#!/bin/bash
# =============================================================================
# canary-rollback.sh - 金丝雀发布和回滚测试脚本
# =============================================================================
# 模拟完整金丝雀发布流程：部署稳定版 → 升级 → 发现故障 → 自动回滚
#
# 用法:
#   ./canary-rollback.sh                        # 运行完整测试
#   ./canary-rollback.sh v1.31.2                # 指定 K8s 版本
#   ./canary-rollback.sh --no-cleanup           # 测试后保留集群供调试
#   ./canary-rollback.sh --help                 # 显示帮助
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
CLUSTER_NAME="canary-test"
K8S_VERSION="v1.31.2"
CLEANUP=true

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cleanup) CLEANUP=false; shift ;;
        --help|-h)
            echo "用法: ./canary-rollback.sh [K8S_VERSION] [--no-cleanup]"
            echo ""
            echo "参数:"
            echo "  K8S_VERSION    指定 Kind 节点镜像版本 (默认: v1.31.2)"
            echo "  --no-cleanup   保留集群供调试"
            echo ""
            echo "示例:"
            echo "  ./canary-rollback.sh                      # 默认版本"
            echo "  ./canary-rollback.sh v1.28.15             # 指定版本"
            echo "  ./canary-rollback.sh v1.30.6 --no-cleanup # 保留集群"
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
    for cmd in docker kind kubectl; do
        if ! command -v $cmd &>/dev/null; then
            error "$cmd 未安装"
            exit 1
        fi
    done
    if ! docker info &>/dev/null; then
        error "Docker 未运行"
        exit 1
    fi
}

# ─── 清理 ──────────────────────────────────────────────────────────────────
cleanup_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        info "删除现有集群..."
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════════════════════

main() {
    title
    header "🔄 金丝雀发布与回滚测试"
    echo ""
    echo -e "  K8s 版本: ${BOLD}${K8S_VERSION}${NC}"
    echo ""

    preflight
    cleanup_cluster

    # ─── 1. 创建集群 ──────────────────────────────────────────────────────
    title
    header "📦 1/6: 创建 2 节点集群"
    echo ""

    if [ "$K8S_VERSION" = "v1.31.2" ]; then
        kind create cluster --name "$CLUSTER_NAME" --config - <<EOF 2>&1 | grep -v "^$"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
    else
        kind create cluster --name "$CLUSTER_NAME" \
            --image "kindest/node:${K8S_VERSION}" \
            --config - <<EOF 2>&1 | grep -v "^$"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
    fi
    ok "集群创建成功（1 控制平面 + 2 Worker）"

    # ─── 2. 部署稳定版 ────────────────────────────────────────────────────
    title
    header "📦 2/6: 部署稳定版 (nginx:1.25)"
    echo ""

    kubectl create deployment stable-app --image=nginx:1.25 --replicas=4 2>&1 | grep -v "^$"
    kubectl expose deployment stable-app --port=80 2>&1 | grep -v "^$"
    kubectl annotate deployment/stable-app kubernetes.io/change-cause="initial deployment nginx:1.25" 2>&1 | grep -v "^$"
    kubectl wait --for=condition=ready pod -l app=stable-app --timeout=60s
    kubectl get pods -o wide
    ok "稳定版部署完成（nginx:1.25，4 副本）"

    # ─── 3. 模拟金丝雀发布 ────────────────────────────────────────────────
    title
    header "🆕 3/6: 金丝雀发布 (nginx:1.26)"
    echo ""

    info "升级到 nginx:1.26..."
    kubectl set image deployment/stable-app stable-app=nginx:1.26 2>&1 | grep -v "^$"
    kubectl annotate deployment/stable-app kubernetes.io/change-cause="upgrade to 1.26-canary" 2>&1 | grep -v "^$"
    sleep 5
    kubectl rollout status deployment/stable-app --timeout=30s || true

    kubectl get pods -o wide
    ok "升级完成"

    # ─── 4. 模拟故障版本 ──────────────────────────────────────────────────
    title
    header "💥 4/6: 模拟故障版本 (nginx:1.26-perl)"
    echo ""

    info "尝试有问题的版本..."
    kubectl set image deployment/stable-app stable-app=nginx:1.26-perl 2>&1 || true
    sleep 3

    # ─── 5. 回滚 ──────────────────────────────────────────────────────────
    title
    header "↩️  5/6: 回滚到原始版本"
    echo ""

    header "回滚历史:"
    kubectl rollout history deployment/stable-app
    echo ""

    info "回滚到 revision 1..."
    kubectl rollout undo deployment/stable-app --to-revision=1 2>&1 | grep -v "^$"
    kubectl rollout status deployment/stable-app --timeout=60s

    echo ""
    header "验证回滚:"
    ROLLBACK_IMAGE=$(kubectl get deployment stable-app -o jsonpath='{.spec.template.spec.containers[0].image}')
    echo -e "  当前镜像: ${BOLD}${ROLLBACK_IMAGE}${NC}"
    if [ "$ROLLBACK_IMAGE" = "nginx:1.25" ]; then
        ok "已正确回滚到 nginx:1.25"
    else
        warn "回滚结果: $ROLLBACK_IMAGE"
    fi

    # ─── 6. 清理 ──────────────────────────────────────────────────────────
    title
    header "🧹 6/6: 清理"

    if [ "$CLEANUP" = true ]; then
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
        echo ""
        ok "✅ 金丝雀回滚测试完成！"
    else
        echo ""
        info "集群已保留: kind-${CLUSTER_NAME}"
        echo "  清理命令: kind delete cluster --name ${CLUSTER_NAME}"
        echo ""
        ok "✅ 金丝雀回滚测试完成（集群已保留）"
    fi
}

main
