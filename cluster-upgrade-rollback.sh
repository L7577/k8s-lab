#!/bin/bash
# =============================================================================
# cluster-upgrade-rollback.sh - 集群版本升级/回滚模拟脚本
# =============================================================================
# 模拟 K8s 集群版本升级和回滚流程
# Kind 不支持原地升级，采用"销毁重建"方式模拟
#
# 用法:
#   ./cluster-upgrade-rollback.sh                                    # 默认版本
#   ./cluster-upgrade-rollback.sh v1.27.3 v1.31.2                   # 指定旧版和新版
#   ./cluster-upgrade-rollback.sh v1.28.15 v1.31.2 --no-cleanup     # 保留集群
#   ./cluster-upgrade-rollback.sh --help                             # 显示帮助
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
CLUSTER_NAME="upgrade-test"
OLD_VERSION="v1.28.15"
NEW_VERSION="v1.31.2"
CLEANUP=true

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cleanup) CLEANUP=false; shift ;;
        --help|-h)
            echo "用法: ./cluster-upgrade-rollback.sh [旧版本] [新版本] [--no-cleanup]"
            echo ""
            echo "参数:"
            echo "  旧版本         起始 K8s 版本 (默认: v1.28.15)"
            echo "  新版本         目标 K8s 版本 (默认: v1.31.2)"
            echo "  --no-cleanup   保留最后一个集群供调试"
            echo ""
            echo "示例:"
            echo "  ./cluster-upgrade-rollback.sh"
            echo "  ./cluster-upgrade-rollback.sh v1.27.3 v1.31.2"
            echo "  ./cluster-upgrade-rollback.sh v1.30.6 v1.31.2 --no-cleanup"
            exit 0
            ;;
        --*) error "未知参数: $1"; exit 1 ;;
        *)
            if [ -z "${ARG_OLD:-}" ]; then
                OLD_VERSION="$1"
                [[ "$OLD_VERSION" != v* ]] && OLD_VERSION="v${OLD_VERSION}"
                ARG_OLD="set"
            elif [ -z "${ARG_NEW:-}" ]; then
                NEW_VERSION="$1"
                [[ "$NEW_VERSION" != v* ]] && NEW_VERSION="v${NEW_VERSION}"
                ARG_NEW="set"
            fi
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

# ─── 创建多节点集群 ────────────────────────────────────────────────────────
create_cluster() {
    local VERSION="$1"
    local NODE_IMAGE="kindest/node:${VERSION}"

    kind create cluster \
        --name "$CLUSTER_NAME" \
        --image "$NODE_IMAGE" \
        --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
}

# ══════════════════════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════════════════════

main() {
    title
    header "🔄 集群版本升级/回滚模拟"
    echo ""
    echo -e "  📌 旧版本: ${BOLD}${OLD_VERSION}${NC}"
    echo -e "  📌 新版本: ${BOLD}${NEW_VERSION}${NC}"
    echo ""

    preflight
    cleanup_cluster

    # ─── 1. 以旧版本创建集群 ──────────────────────────────────────────────
    title
    header "📦 1/4: 创建 ${OLD_VERSION} 集群"
    echo ""

    info "创建 ${OLD_VERSION} 多节点集群..."
    create_cluster "$OLD_VERSION" 2>&1 | grep -v "^$"
    ok "${OLD_VERSION} 集群创建成功（1 控制平面 + 2 Worker）"

    # ─── 2. 部署应用 ──────────────────────────────────────────────────────
    title
    header "📦 2/4: 在 ${OLD_VERSION} 上部署应用"
    echo ""

    kubectl create deployment nginx --image=nginx:alpine --replicas=3 2>&1 | grep -v "^$"
    kubectl wait --for=condition=ready pod -l app=nginx --timeout=60s
    kubectl get pods -o wide
    ok "应用正常运行在 ${OLD_VERSION}"

    echo ""
    header "节点状态（${OLD_VERSION}）:"
    kubectl get nodes -o wide

    # ─── 3. 模拟升级 ──────────────────────────────────────────────────────
    title
    header "⬆️  3/4: 模拟升级到 ${NEW_VERSION}"
    echo ""

    info "销毁 ${OLD_VERSION} 集群..."
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
    sleep 3

    info "创建 ${NEW_VERSION} 集群..."
    create_cluster "$NEW_VERSION" 2>&1 | grep -v "^$"
    ok "集群已升级到 ${NEW_VERSION}"

    kubectl get nodes
    echo ""
    warn "注意：Kind 不支持原地升级，升级过程中应用和数据已丢失。"
    warn "在生产环境中，kubeadm 升级会保留 etcd 数据和工作负载。"

    # ─── 4. 回滚到旧版本 ──────────────────────────────────────────────────
    title
    header "↩️  4/4: 回滚到 ${OLD_VERSION}"
    echo ""

    info "销毁 ${NEW_VERSION} 集群..."
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
    sleep 3

    info "创建 ${OLD_VERSION} 集群..."
    create_cluster "$OLD_VERSION" 2>&1 | grep -v "^$"
    ok "集群已回滚到 ${OLD_VERSION}"

    echo ""
    header "验证回滚:"
    kubectl get nodes

    # ─── 清理 ──────────────────────────────────────────────────────────────
    title
    header "🧹 清理"

    if [ "$CLEANUP" = true ]; then
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
        echo ""
        ok "✅ 集群版本升级/回滚模拟完成！"
    else
        echo ""
        info "集群已保留: kind-${CLUSTER_NAME}"
        echo "  清理命令: kind delete cluster --name ${CLUSTER_NAME}"
        echo ""
        ok "✅ 集群版本升级/回滚模拟完成（集群已保留）"
    fi
}

main
