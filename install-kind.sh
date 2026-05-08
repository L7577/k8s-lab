#!/bin/bash
# =============================================================================
# Kind (Kubernetes in Docker) 安装脚本
# 遵循 https://kind.sigs.k8s.io/docs/user/quick-start/#installation
# 用法：
#   sudo bash install-kind.sh --install           # 安装/更新最新版
#   sudo bash install-kind.sh --install v0.30.0   # 安装/更新指定版本
#   sudo bash install-kind.sh --uninstall         # 卸载
#   bash install-kind.sh --check                  # 检查 Kind
# =============================================================================

set -e
INSTALL_DIR="/usr/local/bin"

get_installed_version() {
    command -v kind &>/dev/null || return 1
    kind version 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# 尝试多个下载源，返回第一个成功的下载链接
try_download() {
    local FILE="$1" URL="$2"
    local SOURCES=(
        "https://kind.sigs.k8s.io/dl/${URL}"
        "https://github.com/kubernetes-sigs/kind/releases/download/${URL}"
    )
    for SRC in "${SOURCES[@]}"; do
        echo "    尝试: $SRC" >&2
        if command -v curl &>/dev/null; then
            HTTP_CODE=$(curl -sS -w "%{http_code}" -L --connect-timeout 150 --max-time 1200 \
                -o "$FILE" "$SRC") || HTTP_CODE="000"
            if [ "$HTTP_CODE" = "200" ]; then
                echo "$SRC"
                return 0
            fi
            echo "    → curl 失败（HTTP $HTTP_CODE）" >&2
        fi
        if command -v wget &>/dev/null; then
            echo "    → 改用 wget 重试..." >&2
            if wget -q --timeout=150 --tries=3 -O "$FILE" "$SRC" 2>/dev/null; then
                echo "$SRC"
                return 0
            fi
            echo "    → wget 也失败" >&2
        fi
    done
    return 1
}

install_kind() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：安装需要 root 权限，请使用 sudo 运行" >&2
        exit 1
    fi

    # 确定架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) KIND_ARCH="amd64" ;;
        aarch64|arm64) KIND_ARCH="arm64" ;;
        *) echo "错误：不支持的架构: $ARCH" >&2; exit 1 ;;
    esac

    # 确定版本
    KIND_VERSION="${1:-latest}"
    if [ "$KIND_VERSION" = "latest" ]; then
        echo "获取最新版本..."
        # 先尝试 curl
        if command -v curl &>/dev/null; then
            KIND_VERSION=$(curl -fsSL --connect-timeout 10 \
                "https://api.github.com/repos/kubernetes-sigs/kind/releases/latest" \
                2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)",.*/\1/' || true)
            if [ -z "$KIND_VERSION" ]; then
                KIND_VERSION=$(curl -fsSL --connect-timeout 10 \
                    -o /dev/null -w '%{redirect_url}' \
                    "https://github.com/kubernetes-sigs/kind/releases/latest" \
                    2>/dev/null | grep -oP 'tag/\K(v[0-9.]+)' || true)
            fi
        fi
        # curl 失败或无 curl 时，改用 wget
        if [ -z "$KIND_VERSION" ] && command -v wget &>/dev/null; then
            echo "  curl 不可用或失败，改用 wget..." >&2
            KIND_VERSION=$(wget -q --timeout=10 -O - \
                "https://api.github.com/repos/kubernetes-sigs/kind/releases/latest" \
                2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)",.*/\1/' || true)
        fi
        [ -z "$KIND_VERSION" ] && { echo "错误：无法获取最新版本" >&2; exit 1; }
        echo "最新版本：${KIND_VERSION}"
    fi
    [[ "$KIND_VERSION" != v* ]] && KIND_VERSION="v${KIND_VERSION}"

    # 比对版本，相同则跳过
    INSTALLED_VERSION=$(get_installed_version || true)
    if [ -n "$INSTALLED_VERSION" ]; then
        if [ "$INSTALLED_VERSION" = "$KIND_VERSION" ]; then
            echo "Kind ${INSTALLED_VERSION} 已是最新版本，无需安装"
            exit 0
        fi
        echo "版本更新：${INSTALLED_VERSION} → ${KIND_VERSION}"
    fi

    URL_PATH="${KIND_VERSION}/kind-linux-${KIND_ARCH}"
    echo "下载: kind-linux-${KIND_ARCH}"

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # 多源下载
    echo "尝试下载..."
    DOWNLOAD_URL=$(try_download "${TMP_DIR}/kind" "$URL_PATH") || {
        echo "错误：所有下载源均失败" >&2
        echo "  请检查网络连接或代理设置" >&2
        exit 1
    }
    echo "  成功: ${DOWNLOAD_URL}"

    # 安装
    chmod +x "${TMP_DIR}/kind"
    mv "${TMP_DIR}/kind" "${INSTALL_DIR}/kind"
    echo "Kind ${KIND_VERSION} 已安装到 ${INSTALL_DIR}/kind"
    kind version
}

uninstall_kind() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：卸载需要 root 权限，请使用 sudo 运行" >&2
        exit 1
    fi
    KIND_PATH=$(command -v kind 2>/dev/null || true)
    if [ -n "$KIND_PATH" ]; then
        rm -f "$KIND_PATH"
        echo "已删除: $KIND_PATH"
    fi
    if command -v kind &>/dev/null; then
        echo "警告：kind 在其他路径仍存在: $(command -v kind)" >&2
    else
        echo "kind 已完全卸载"
    fi
}

check_kind() {
    KIND_PATH=$(command -v kind 2>/dev/null || true)
    if [ -n "$KIND_PATH" ]; then
        echo "kind 路径: $KIND_PATH"
        kind version 2>/dev/null | head -1
    else
        echo "kind 未安装"
    fi
}

case "${1:-}" in
    --install|-i) install_kind "${2:-latest}" ;;
    --uninstall|-u) uninstall_kind ;;
    --check|-c) check_kind ;;
    *)
        echo "用法: sudo bash $0 [选项] [版本]"
        echo "  --install, -i [版本]  安装/更新 Kind"
        echo "  --uninstall, -u       卸载 Kind"
        echo "  --check, -c           检查 Kind"
        ;;
esac
