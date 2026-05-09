# =============================================================================
# k8s-lab Makefile - 一键部署、测试、清理
# =============================================================================
# 用法:
#   make help          - 显示帮助信息
#   make install       - 安装所有依赖（Docker + Kind + kubectl）
#   make cluster       - 创建 Kind 集群（默认 4 节点）
#   make cluster-2node - 创建 2 节点轻量集群
#   make cluster-ha    - 创建 HA 集群（3CP + 2W）
#   make cluster-calico - 创建 Calico CNI 测试集群
#   make test          - 运行全部功能测试
#   make test-basic    - 运行基础部署测试
#   make test-scale    - 运行扩缩容测试
#   make test-heal     - 运行自愈测试
#   make test-storage  - 运行存储测试
#   make test-resource - 运行资源限制测试
#   make test-canary   - 运行金丝雀回滚测试
#   make ci            - 运行本地 CI 模拟（完整流水线）
#   make quick         - 5 分钟快速实验（安装→部署→测试→清理）
#   make clean         - 清理所有 Kind 集群
#   make clean-all     - 清理集群 + 卸载工具
#   make logs          - 导出 Kind 集群日志
#   make info          - 查看环境状态
# =============================================================================

SHELL := /bin/bash
.ONESHELL:

# ─── 颜色输出 ──────────────────────────────────────────────────────────────
BLUE	= \033[0;34m
GREEN	= \033[0;32m
YELLOW	= \033[1;33m
CYAN	= \033[0;36m
BOLD	= \033[1m
NC	= \033[0m

# ─── 变量 ──────────────────────────────────────────────────────────────────
K8S_VERSION ?= v1.31.2
CLUSTER_CONFIG ?= kind-cluster.yaml

.PHONY: help install cluster cluster-2node cluster-ha cluster-calico \
        test test-basic test-scale test-heal test-storage test-resource test-canary \
        test-network test-calico \
        quick ci clean clean-all logs info

# ─── 帮助 ──────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo -e "$(BOLD)╔══════════════════════════════════════════════╗$(NC)"
	@echo -e "$(BOLD)║     ☸️  k8s-lab - K8s 实验环境管理            ║$(NC)"
	@echo -e "$(BOLD)╚══════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo -e "$(BOLD)📦 安装管理$(NC)"
	@echo -e "  $(CYAN)make install$(NC)        - 安装所有依赖"
	@echo -e "  $(CYAN)make info$(NC)           - 查看环境状态"
	@echo ""
	@echo -e "$(BOLD)☸️  集群管理$(NC)"
	@echo -e "  $(CYAN)make cluster$(NC)        - 创建标准 4 节点集群"
	@echo -e "  $(CYAN)make cluster-2node$(NC)  - 创建 2 节点轻量集群"
	@echo -e "  $(CYAN)make cluster-ha$(NC)     - 创建 HA 集群"
	@echo -e "  $(CYAN)make cluster-calico$(NC) - 创建 Calico CNI 集群"
	@echo -e "  $(CYAN)make logs$(NC)           - 导出集群日志"
	@echo -e "  $(CYAN)make clean$(NC)          - 清理所有集群"
	@echo ""
	@echo -e "$(BOLD)🧪 测试$(NC)"
	@echo -e "  $(CYAN)make test$(NC)           - 运行全部测试"
	@echo -e "  $(CYAN)make test-basic$(NC)     - 基础部署测试"
	@echo -e "  $(CYAN)make test-scale$(NC)     - 扩缩容测试"
	@echo -e "  $(CYAN)make test-heal$(NC)      - 自愈测试"
	@echo -e "  $(CYAN)make test-storage$(NC)   - 存储测试"
	@echo -e "  $(CYAN)make test-resource$(NC)  - 资源限制测试"
	@echo -e "  $(CYAN)make test-canary$(NC)    - 金丝雀回滚测试"
	@echo -e "  $(CYAN)make test-network$(NC)   - 网络连通性测试"
	@echo -e "  $(CYAN)make test-calico$(NC)    - Calico CNI 测试（独立集群）"
	@echo ""
	@echo -e "$(BOLD)🚀 快速体验$(NC)"
	@echo -e "  $(CYAN)make ci$(NC)             - 本地 CI 模拟"
	@echo -e "  $(CYAN)make quick$(NC)          - 5 分钟快速实验"
	@echo ""
	@echo -e "$(BOLD)示例:$(NC)"
	@echo -e "  make K8S_VERSION=v1.28.15 cluster          # 指定版本创建集群"
	@echo -e "  make K8S_VERSION=v1.30.6 ci                # 指定版本的 CI 测试"

# ─── 安装 ──────────────────────────────────────────────────────────────────
install:
	@echo -e "$(BLUE)[INFO]$(NC)  开始检测并安装依赖..."
	@echo ""
	@NEED_RELOGIN=false; \
	 \
	 echo -e "$(BOLD)▶ 检查 Docker...$(NC)"; \
	 if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then \
	 	echo -e "  $(GREEN)✓ Docker 已安装$(NC) ($(docker --version 2>/dev/null))"; \
	 else \
	 	echo -e "  $(YELLOW)⚠ Docker 未安装或未运行，开始安装...$(NC)"; \
	 	sudo bash install-docker.sh --install || { echo -e "  $(RED)✗ Docker 安装失败$(NC)"; exit 1; }; \
	 	NEED_RELOGIN=true; \
	 fi; \
	 \
	 echo ""; \
	 echo -e "$(BOLD)▶ 检查 Kind...$(NC)"; \
	 if command -v kind &>/dev/null; then \
	 	echo -e "  $(GREEN)✓ Kind 已安装$(NC) ($(kind version 2>/dev/null))"; \
	 else \
	 	echo -e "  $(YELLOW)⚠ Kind 未安装，开始安装...$(NC)"; \
	 	sudo bash install-kind.sh --install || { echo -e "  $(RED)✗ Kind 安装失败$(NC)"; exit 1; }; \
	 fi; \
	 \
	 echo ""; \
	 echo -e "$(BOLD)▶ 检查 kubectl...$(NC)"; \
	 if command -v kubectl &>/dev/null; then \
	 	echo -e "  $(GREEN)✓ kubectl 已安装$(NC) ($(kubectl version --client 2>/dev/null | head -1))"; \
	 else \
	 	echo -e "  $(YELLOW)⚠ kubectl 未安装，开始安装...$(NC)"; \
	 	sudo bash install-kubectl.sh --install || { echo -e "  $(RED)✗ kubectl 安装失败$(NC)"; exit 1; }; \
	 fi; \
	 \
	 echo ""; \
	 echo -e "$(GREEN)[OK]$(NC)    所有依赖安装完成！"; \
	 echo ""; \
	 if [ "$$NEED_RELOGIN" = "true" ]; then \
	 	echo -e "$(YELLOW)[WARN]$(NC)  docker 组有变更，请执行以下命令生效:"; \
	 	echo -e "  $(CYAN)exec newgrp docker$(NC)"; \
	 fi

# ─── 集群创建 ──────────────────────────────────────────────────────────────
cluster:
	@echo -e "$(BLUE)[INFO]$(NC)  创建 Kind 集群..."
	@bash setup-k8s-lab.sh --cluster $(CLUSTER_CONFIG)

cluster-2node:
	@K8S_VERSION=$(K8S_VERSION) bash setup-k8s-lab.sh --cluster kind-2nodes.yaml

cluster-ha:
	@bash setup-k8s-lab.sh --cluster kind-ha.yaml

cluster-calico:
	@bash setup-k8s-lab.sh --cluster kind-calico.yaml

# ─── 测试 ──────────────────────────────────────────────────────────────────

# 辅助：检查集群是否存在，不存在则自动创建
ensure_cluster:
	@if ! kubectl cluster-info &>/dev/null 2>&1; then \
		echo -e "$(YELLOW)[WARN]$(NC)  Kind 集群未运行，自动创建集群..."; \
		bash setup-k8s-lab.sh --cluster $(CLUSTER_CONFIG); \
		echo ""; \
	fi

test: ensure_cluster
	@echo -e "$(BLUE)[INFO]$(NC)  运行全部功能测试..."
	@bash setup-k8s-lab.sh --test all

test-basic: ensure_cluster
	@bash setup-k8s-lab.sh --test basic

test-scale: ensure_cluster
	@bash setup-k8s-lab.sh --test scale

test-heal: ensure_cluster
	@bash setup-k8s-lab.sh --test self-heal

test-storage: ensure_cluster
	@bash setup-k8s-lab.sh --test storage

test-resource: ensure_cluster
	@bash setup-k8s-lab.sh --test resource

test-canary: ensure_cluster
	@bash setup-k8s-lab.sh --test canary

test-network: ensure_cluster
	@bash setup-k8s-lab.sh --test network

test-calico:
	@bash setup-k8s-lab.sh --test calico

# ─── 快速实验 ──────────────────────────────────────────────────────────────
quick:
	@bash quick-experiment.sh

# ─── CI 模拟 ───────────────────────────────────────────────────────────────
ci:
	@bash local-ci.sh $(K8S_VERSION)

# ─── 清理 ──────────────────────────────────────────────────────────────────
clean:
	@echo -e "$(YELLOW)[WARN]$(NC)  删除所有 Kind 集群..."
	@kind get clusters 2>/dev/null | while read cl; do \
		echo "  - 删除集群: $$cl"; \
		kind delete cluster --name "$$cl" 2>/dev/null; \
	done
	@echo -e "$(GREEN)[OK]$(NC)    清理完成"

clean-all: clean
	@echo ""
	@echo -e "$(YELLOW)[WARN]$(NC)  开始卸载所有工具..."
	@sudo bash setup-k8s-lab.sh --cleanup
	@echo -e "$(GREEN)[OK]$(NC)    清理完成"

# ─── 日志导出 ──────────────────────────────────────────────────────────────
logs:
	@mkdir -p ./kind-logs
	@kind get clusters 2>/dev/null | while read cl; do \
		echo "  - 导出集群 $$cl 日志..."; \
		kind export logs ./kind-logs/$$cl --name "$$cl" 2>/dev/null; \
	done
	@echo -e "$(GREEN)[OK]$(NC)    日志已导出到 ./kind-logs/"

# ─── 环境信息 ──────────────────────────────────────────────────────────────
info:
	@bash setup-k8s-lab.sh --check
