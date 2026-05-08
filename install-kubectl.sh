#!/bin/bash
# =============================================================================
# kubectl 安装脚本 — 遵循 https://kubernetes.io/zh-cn/docs/tasks/tools/install-kubectl-linux/
# 用法：
#   sudo bash install-kubectl.sh --install          # 安装/更新最新版
#   sudo bash install-kubectl.sh --install v1.31.0  # 安装/更新指定版本
#   sudo bash install-kubectl.sh --uninstall        # 卸载
#   bash install-kubectl.sh --check                 # 检查 kubectl
# =============================================================================

set -e
K8S_DL_BASE="https://dl.k8s.io"
INSTALL_DIR="/usr/local/bin"

get_installed_version() {
    command -v kubectl &>/dev/null || return 1
    kubectl version --client 2>/dev/null | grep -oP 'GitVersion:"\K[v0-9.]+' || true
}

install_kubectl() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：安装需要 root 权限，请使用 sudo 运行" >&2
        exit 1
    fi

    # 确定架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) KUBECTL_ARCH="amd64" ;;
        aarch64|arm64) KUBECTL_ARCH="arm64" ;;
        *) echo "错误：不支持的架构: $ARCH" >&2; exit 1 ;;
    esac

    # 确定版本
    KUBECTL_VERSION="${1:-latest}"
    if [ "$KUBECTL_VERSION" = "latest" ]; then
        echo "获取最新稳定版本..."
        KUBECTL_VERSION=$(curl -fsSL --connect-timeout 10 "https://dl.k8s.io/release/stable.txt")
        [ -z "$KUBECTL_VERSION" ] && { echo "错误：无法获取最新版本" >&2; exit 1; }
        echo "最新版本：${KUBECTL_VERSION}"
    fi
    [[ "$KUBECTL_VERSION" != v* ]] && KUBECTL_VERSION="v${KUBECTL_VERSION}"

    # 比对版本，相同则跳过
    INSTALLED_VERSION=$(get_installed_version || true)
    if [ -n "$INSTALLED_VERSION" ]; then
        if [ "$INSTALLED_VERSION" = "$KUBECTL_VERSION" ]; then
            echo "kubectl ${INSTALLED_VERSION} 已是最新版本，无需安装"
            exit 0
        fi
        echo "版本更新：${INSTALLED_VERSION} → ${KUBECTL_VERSION}"
    fi

    DOWNLOAD_URL="${K8S_DL_BASE}/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
    echo "下载: ${DOWNLOAD_URL}"

    TMP_DIR=$(mktemp -d)
    CLEANUP_TMP=true
    trap 'if [ "$CLEANUP_TMP" = true ]; then rm -rf "$TMP_DIR"; fi' EXIT

    # 下载二进制
    HTTP_CODE=$(curl -sS -w "%{http_code}" --connect-timeout 15 --max-time 120 \
        -o "${TMP_DIR}/kubectl" "$DOWNLOAD_URL") || HTTP_CODE="000"
    if [ "$HTTP_CODE" != "200" ]; then
        echo "错误：下载失败（HTTP $HTTP_CODE）" >&2
        echo "  下载地址：$DOWNLOAD_URL" >&2
        exit 1
    fi

    # 校验 SHA256
    CHECKSUM_URL="${DOWNLOAD_URL}.sha256"
    HTTP_CODE_CS=$(curl -sS -w "%{http_code}" --connect-timeout 10 --max-time 30 \
        -o "${TMP_DIR}/kubectl.sha256" "$CHECKSUM_URL" 2>&1) || true
    if [ "$HTTP_CODE_CS" = "200" ]; then
        EXPECTED=$(cut -d' ' -f1 "${TMP_DIR}/kubectl.sha256")
        ACTUAL=$(sha256sum "${TMP_DIR}/kubectl" | cut -d' ' -f1)
        if [ "$EXPECTED" != "$ACTUAL" ]; then
            echo "错误：SHA256 校验不匹配" >&2
            echo "  期望值: $EXPECTED" >&2
            echo "  实际值: $ACTUAL" >&2
            echo "  临时文件保留在: $TMP_DIR" >&2
            CLEANUP_TMP=false
            exit 1
        fi
        echo "SHA256 校验通过"
    else
        echo "警告：无法获取 SHA256 校验和（HTTP $HTTP_CODE_CS），跳过验证" >&2
    fi

    # 安装
    chmod +x "${TMP_DIR}/kubectl"
    mv "${TMP_DIR}/kubectl" "${INSTALL_DIR}/kubectl"
    echo "kubectl ${KUBECTL_VERSION} 已安装到 ${INSTALL_DIR}/kubectl"
    kubectl version --client

    # 配置 shell 自动补全
    SHELL_TYPE="${SHELL##*/}"
    if [ "$SHELL_TYPE" = "bash" ]; then
        mkdir -p /etc/bash_completion.d
        kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null && \
            echo "Bash 自动补全已配置（重新登录终端生效）" || \
            echo "警告：Bash 自动补全配置失败" >&2
    elif [ "$SHELL_TYPE" = "zsh" ]; then
        ZSH_COMP_DIR="/usr/local/share/zsh/site-functions"
        mkdir -p "$ZSH_COMP_DIR"
        kubectl completion zsh > "${ZSH_COMP_DIR}/_kubectl" 2>/dev/null && \
            echo "Zsh 自动补全已配置（重新登录终端生效）" || \
            echo "警告：Zsh 自动补全配置失败" >&2
    fi
}

uninstall_kubectl() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：卸载需要 root 权限，请使用 sudo 运行" >&2
        exit 1
    fi
    KUBECTL_PATH=$(command -v kubectl 2>/dev/null || true)
    if [ -n "$KUBECTL_PATH" ]; then
        rm -f "$KUBECTL_PATH"
        echo "已删除: $KUBECTL_PATH"
    fi
    rm -f /etc/bash_completion.d/kubectl /usr/local/share/zsh/site-functions/_kubectl 2>/dev/null || true
    echo "已清理自动补全文件"
    if command -v kubectl &>/dev/null; then
        echo "警告：kubectl 在其他路径仍存在: $(command -v kubectl)" >&2
    else
        echo "kubectl 已完全卸载"
    fi
}

check_kubectl() {
    KUBECTL_PATH=$(command -v kubectl 2>/dev/null || true)
    if [ -n "$KUBECTL_PATH" ]; then
        echo "kubectl 路径: $KUBECTL_PATH"
        kubectl version --client 2>/dev/null | head -1
    else
        echo "kubectl 未安装"
    fi
}

case "${1:-}" in
    --install|-i) install_kubectl "${2:-latest}" ;;
    --uninstall|-u) uninstall_kubectl ;;
    --check|-c) check_kubectl ;;
    *)
        echo "用法: sudo bash $0 [选项] [版本]"
        echo "  --install, -i [版本]  安装/更新 kubectl"
        echo "  --uninstall, -u       卸载 kubectl"
        echo "  --check, -c           检查 kubectl"
        ;;
esac
