#!/bin/bash
# =============================================================================
# Docker 一键安装脚本 — 精简版
# 遵循 https://docs.docker.com/engine/install/ubuntu/
# 特性：幂等（重复执行安全）、静默安装、无交互
# =============================================================================
# 用法:
#   sudo bash install-docker.sh            # 安装 Docker（幂等）
#   sudo bash install-docker.sh --uninstall # 卸载 Docker
#   bash install-docker.sh --check         # 仅检查状态
# =============================================================================

set -euo pipefail

# ─── 颜色 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── 检查系统 ─────────────────────────────────────────────────────────────
check_system() {
    # 仅支持 Ubuntu
    if [ ! -f /etc/os-release ]; then
        error "无法检测操作系统"; exit 1
    fi
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        error "此脚本仅支持 Ubuntu，当前系统为 $ID"; exit 1
    fi
    echo "  系统: $NAME $VERSION_ID ($(uname -m))"
}

# ─── 卸载旧版本 ───────────────────────────────────────────────────────────
uninstall_docker() {
    local force=${1:-false}
    local pkgs=(
        docker-ce docker-ce-cli containerd.io
        docker-buildx-plugin docker-compose-plugin
        docker-ce-rootless-extras
    )
    local legacy=(docker docker-engine docker.io containerd runc)

    info "卸载旧版 Docker 包..."
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "${pkgs[@]}" "${legacy[@]}" 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y 2>/dev/null || true

    if [ "$force" = true ]; then
        info "删除数据目录和 APT 源..."
        rm -rf /var/lib/docker /var/lib/containerd
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.asc
    fi
    ok "卸载完成"
}

# ─── 安装 Docker（幂等） ──────────────────────────────────────────────────
install_docker() {
    # === 1. 前置检查 ===
    if [ "$EUID" -ne 0 ]; then error "请使用 sudo 运行"; exit 1; fi

    check_system

    # === 2. 安装依赖 ===
    info "安装依赖包..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl

    # === 3. 配置 APT 源（幂等） ===
    local keyring="/etc/apt/keyrings/docker.asc"
    local sources="/etc/apt/sources.list.d/docker.list"
    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    info "配置 Docker APT 源..."
    install -m 0755 -d /etc/apt/keyrings

    if [ ! -f "$keyring" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$keyring"
        chmod a+r "$keyring"
        ok "GPG 密钥已添加"
    else
        ok "GPG 密钥已存在，跳过"
    fi

    if [ ! -f "$sources" ]; then
        cat > "$sources" <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
        ok "APT 源已配置（${codename}）"
    else
        ok "APT 源已存在，跳过"
    fi

    # === 4. 安装 Docker（幂等） ===
    info "安装 Docker Engine..."
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # === 5. 启动服务 ===
    systemctl enable docker 2>/dev/null || true
    systemctl start docker

    # === 6. 验证 ===
    echo ""
    docker --version 2>/dev/null && ok "Docker $(docker --version)" || warn "docker --version 异常"
    docker compose version 2>/dev/null && ok "$(docker compose version)" || warn "docker compose 异常"
    docker buildx version 2>/dev/null && ok "Buildx: $(docker buildx version | head -1 | awk '{print $NF}')" || warn "buildx 异常"

    if docker info &>/dev/null; then
        ok "Docker 引擎运行正常"
    else
        error "Docker 引擎异常，请检查: journalctl -u docker"
    fi
}

# ─── 检查状态 ─────────────────────────────────────────────────────────────
check_status() {
    check_system
    echo ""
    echo "  docker 命令: $(command -v docker 2>/dev/null || echo '未安装')"
    docker --version 2>/dev/null && echo "  服务端: $(docker info 2>/dev/null | grep 'Server Version' | awk '{print $NF}')" || echo "  服务端: 未运行"
    docker compose version 2>/dev/null && echo "  Compose: $(docker compose version 2>/dev/null)" || true
    echo "  用户组: $(groups "${SUDO_USER:-$USER}" 2>/dev/null | grep -q docker && echo '✅ 在 docker 组' || echo '❌ 不在 docker 组')"
}

# ─── 用户组修复 ───────────────────────────────────────────────────────────
fix_group() {
    local user="${SUDO_USER:-$USER}"
    getent group docker &>/dev/null || groupadd docker
    if ! groups "$user" 2>/dev/null | grep -qw docker; then
        usermod -aG docker "$user"
        ok "用户 $user 已加入 docker 组，请重新登录生效"
    else
        ok "用户 $user 已在 docker 组中"
    fi
}

# ─── 主入口 ───────────────────────────────────────────────────────────────
main() {
    case "${1:-install}" in
        install|-i)
            install_docker
            fix_group
            echo ""
            ok "安装完成！如 docker 组有变更，请执行: newgrp docker"
            ;;
        uninstall|-u)
            [ "$EUID" -eq 0 ] || { error "请使用 sudo 运行"; exit 1; }
            uninstall_docker true
            ;;
        check|-c)
            check_status
            ;;
        help|-h|--help)
            echo "用法: sudo bash $0 [选项]"
            echo "  无参数 / install    安装 Docker（幂等）"
            echo "  uninstall           彻底卸载 Docker"
            echo "  check               检查安装状态"
            echo "  help                显示此帮助"
            ;;
        *)
            error "未知选项: $1"; exit 1
            ;;
    esac
}

main "$@"
