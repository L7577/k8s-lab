# ☸️ k8s-lab — Kubernetes 单机实验环境

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **在单台物理机上，用 Kind 快速搭建完整的 Kubernetes 实验环境**  
> 零系统侵入、容器化部署、脚本化操作，适合开发测试、CI/CD 模拟与学习实验。

---

## ✨ 项目简介

`k8s-lab` 是一个基于 [Kind (Kubernetes in Docker)](https://kind.sigs.k8s.io/) 的 K8s 实验环境管理工具集，提供**一键安装、集群管理、功能测试、CI/CD 模拟、回滚演练**等能力，全部在单台 Ubuntu 主机上通过容器完成。

### 设计原则

| 原则 | 说明 |
|------|------|
| **零物理机侵入** | 只依赖 Docker，不修改系统配置（不关 swap、不调内核参数） |
| **容器化部署** | K8s 节点全部运行在容器中，删除集群即恢复环境 |
| **标准 K8s 兼容** | 使用原生 Kubernetes 组件，与生产环境行为一致 |
| **脚本化操作** | 所有操作通过脚本完成，避免手工配置出错 |
| **场景覆盖** | CI/CD 集成、自动回滚测试、多节点模拟、网络/存储实验 |

---

## 🚀 快速开始

### 5 分钟快速实验

```bash
# 1️⃣ 安装依赖（仅首次需要）
sudo bash install-docker.sh --install
sudo bash install-kind.sh --install
sudo bash install-kubectl.sh --install
exec newgrp docker

# 2️⃣ 一键快速实验（创建集群 → 部署 Nginx → 自愈/扩容 → 清理）
./quick-experiment.sh
```

或使用 Make 一键安装（自动跳过已安装组件）：

```bash
make install          # 安装所有依赖（已安装则跳过）
exec newgrp docker    # docker 组生效
make quick            # 5 分钟快速实验
```

---

## 📦 安装管理

### Make 命令一览

| 命令 | 说明 |
|------|------|
| `make install` | **智能安装**所有依赖 — 检测已安装组件并自动跳过 |
| `make cluster` | 创建标准 4 节点 Kind 集群 |
| `make cluster-2node` | 创建 2 节点轻量集群 |
| `make cluster-ha` | 创建 HA 高可用集群（3CP + 2W） |
| `make cluster-calico` | 创建 Calico CNI 测试集群 |
| `make test` | 运行全部功能测试 |
| `make test-basic` | 基础部署测试 |
| `make test-scale` | 扩缩容测试 |
| `make test-heal` | 自愈测试 |
| `make test-storage` | 存储测试 |
| `make test-resource` | 资源限制测试 |
| `make test-canary` | 金丝雀回滚测试 |
| `make ci` | 运行本地 CI 模拟（完整流水线） |
| `make quick` | 5 分钟快速实验 |
| `make clean` | 清理所有 Kind 集群 |
| `make clean-all` | 清理集群 + 卸载工具 |
| `make logs` | 导出 Kind 集群日志 |
| `make info` | 查看环境状态 |
| `make help` | 查看全部命令 |

> 💡 **智能安装说明**：`make install` 会逐一检测 Docker、Kind、kubectl 是否已安装运行。  
> - 已安装的组件自动跳过，不会重复下载  
> - 缺失的组件自动安装  
> - 安装完成后提示是否需要重新登录 docker 组

### 各组件独立安装

| 组件 | 安装 | 检查 | 卸载 |
|------|------|------|------|
| **Docker** | `sudo bash install-docker.sh --install` | `--check` | `--uninstall` |
| **Kind** | `sudo bash install-kind.sh --install [版本]` | `--check` | `--uninstall` |
| **kubectl** | `sudo bash install-kubectl.sh --install [版本]` | `--check` | `--uninstall` |

> 所有脚本支持无参数启动交互式菜单，以及 `--install [版本]` 指定版本安装。

---

## 📋 核心脚本

| 脚本 | 用途 |
|------|------|
| `quick-experiment.sh` | 🚀 5 分钟快速实验 — 创建集群 → 部署 → 测试 → 清理 |
| `local-ci.sh` | 🔄 本地 CI/CD 模拟 — 8 步流水线完整模拟 |
| `setup-k8s-lab.sh` | 🎛️ 统一管理入口 — 交互式菜单 + CLI 模式 |
| `canary-rollback.sh` | 🔄 金丝雀发布与自动回滚测试 |
| `cluster-upgrade-rollback.sh` | ⬆️ 集群版本升级与回滚模拟 |

### Kind 集群配置

| 配置文件 | 节点 | 场景 |
|---------|------|------|
| `kind-2nodes.yaml` | 1CP + 1W | 资源受限环境（4GB 内存） |
| `kind-cluster.yaml` | 1CP + 3W | 日常开发 / CI 测试 |
| `kind-ha.yaml` | 3CP + 2W | HA 高可用测试 |
| `kind-full.yaml` | 1CP + 3W | 端口映射 + 挂载 |
| `kind-calico.yaml` | 1CP + 2W | Calico CNI 测试 |
| `kind-no-cni.yaml` | 1CP + 2W | 自定义 CNI 实验 |

---

## 🔧 环境要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| 操作系统 | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 16 GB |
| 磁盘 | 20 GB | 40 GB SSD |

---

## 📖 完整文档

请参阅 [`k8s-lab.md`](k8s-lab.md) 获取完整的操作指南，包括：

- 本地 CI 流水线详解
- 金丝雀发布与回滚测试
- 集群版本升级与回滚
- 手工操作参考
- 常见问题排查

---

## 项目结构

```
k8s-lab/
├── install-docker.sh            # Docker 安装/管理
├── install-kind.sh              # Kind 安装/管理
├── install-kubectl.sh           # kubectl 安装/管理
├── setup-k8s-lab.sh             # 统一管理入口
├── quick-experiment.sh          # 快速实验
├── local-ci.sh                  # CI/CD 模拟
├── canary-rollback.sh           # 金丝雀回滚测试
├── cluster-upgrade-rollback.sh  # 集群升级回滚
├── deploy-example.yaml          # 示例部署配置
├── Makefile                     # 一键管理入口
├── kind-2nodes.yaml             # 2 节点轻量集群
├── kind-calico.yaml             # Calico CNI 配置
├── kind-cluster.yaml            # 标准 4 节点集群
├── kind-full.yaml               # 端口映射 + 挂载
├── kind-ha.yaml                 # HA 高可用集群
├── kind-no-cni.yaml             # 自定义 CNI 配置
├── k8s-lab.md                   # 完整文档
├── README.md                    # 项目简介
└── SYSTEM-IMPACT.md             # 系统影响说明
```

---

> **文档维护**：Kind 版本参考 [kind releases](https://github.com/kubernetes-sigs/kind/releases)，K8s 镜像标签参考 [kindest/node tags](https://hub.docker.com/r/kindest/node/tags)。
