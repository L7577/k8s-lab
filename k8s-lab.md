# Kubernetes 单物理机实验环境搭建指南（Ubuntu 22.04）

## 设计原则

- **零物理机侵入**：只依赖 Docker，不修改系统配置（不关 swap、不调内核参数）
- **容器化部署**：K8s 节点全部运行在容器中，删除集群即恢复环境
- **标准 K8s 兼容**：使用原生 Kubernetes 组件，与生产环境行为一致
- **脚本化安装**：所有组件环境部署均通过脚本完成，避免手工配置出错
- **场景覆盖**：CI/CD 集成、自动回滚测试、多节点模拟、网络/存储实验

---

> 🚀 **5 分钟快速实验**：一条命令即可完成从零搭建集群、部署应用、核心测试全流程。
>
> ```bash
> # 确保工具已安装（仅首次需要）
> sudo bash install-docker.sh --install
> sudo bash install-kind.sh --install
> sudo bash install-kubectl.sh --install
> exec newgrp docker
>
> # 5 分钟快速实验（创建集群 → 部署 Nginx → 自愈/扩容 → 清理）
> ./quick-experiment.sh
> ```

---

## 目录

1. [环境要求](#1-环境要求)
2. [一键安装](#2-一键安装)
3. [脚本速查表](#3-脚本速查表)
4. [快速实验](#4-快速实验)
5. [本地 CI 流水线](#5-本地-ci-流水线)
6. [完整部署管理](#6-完整部署管理)
7. [独立测试脚本](#7-独立测试脚本)
8. [Kind 集群配置](#8-kind-集群配置)
9. [手工操作参考](#9-手工操作参考)
10. [常见问题](#10-常见问题)

---

## 1. 环境要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| 操作系统 | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 16 GB |
| 磁盘 | 20 GB | 40 GB SSD |
| 网络 | 可访问互联网 | 可访问互联网 |

---

## 2. 一键安装

### 2.1 安装所有依赖（一条命令）

```bash
# 从零开始，一条命令安装全部依赖
sudo bash install-docker.sh --install
sudo bash install-kind.sh --install
sudo bash install-kubectl.sh --install

# 重新登录使 docker 组生效
exec newgrp docker
```

### 2.2 各脚本独立用法

| 脚本 | 安装 | 检查 | 卸载 |
|------|------|------|------|
| `install-docker.sh` | `--install` | `--check` | `--uninstall` |
| `install-kind.sh` | `--install [版本]` | `--check` | `--uninstall` |
| `install-kubectl.sh` | `--install [版本]` | `--check` | `--uninstall` |

所有脚本无参数时启动**交互式菜单**，支持版本指定。

---

## 3. 脚本速查表

| 脚本 | 用途 | 一句话说明 |
|------|------|-----------|
| `quick-experiment.sh` | 🚀 5 分钟快速实验 | 创建集群 → 部署 Nginx → 自愈/扩容 → 清理，一条命令 |
| `local-ci.sh` | 🔄 本地 CI/CD 模拟 | 8 步流水线：前置检查 → 集群 → 部署 → 端口转发 → 扩容 → 自愈 → 回滚 → 清理 |
| `setup-k8s-lab.sh` | 🎛️ 完整部署管理 | 交互式菜单或 CLI 模式，支持安装/集群/测试/清理全功能 |
| `canary-rollback.sh` | 🔄 金丝雀发布回滚测试 | 部署稳定版 → 金丝雀发布 → 故障模拟 → 自动回滚 |
| `cluster-upgrade-rollback.sh` | ⬆️ 集群版本升级回滚模拟 | 旧版集群 → 部署应用 → 升级新版 → 回滚旧版 |

> 💡 **新手推荐流程**：
> 1. 首次使用：运行 `sudo bash setup-k8s-lab.sh --all` 完成全套流程
> 2. 日常快速验证：运行 `./quick-experiment.sh`
> 3. CI 模拟：运行 `./local-ci.sh`
> 4. 特定测试：运行 `./canary-rollback.sh` 或 `./cluster-upgrade-rollback.sh`

---

## 4. 快速实验

```bash
# 默认版本快速实验（自动创建 4 节点集群 + 部署测试 + 清理）
./quick-experiment.sh

# 指定 K8s 版本
./quick-experiment.sh v1.28.15

# 保留集群供进一步探索
./quick-experiment.sh v1.30.6 --keep
```

**实验内容**：
1. 创建 4 节点集群（1 控制平面 + 3 Worker）
2. 部署 Nginx（2 副本）
3. 端口转发验证服务可访问
4. 自愈测试（删除 Pod 自动重建）
5. 扩容测试（2 → 5 副本）
6. 自动清理或保留集群

---

## 5. 本地 CI 流水线

模拟 CI/CD 流程，无需提交代码即可测试完整部署流水线：

```bash
# 使用默认版本
./local-ci.sh

# 指定 K8s 版本
./local-ci.sh v1.28.15

# 保留集群供调试
./local-ci.sh v1.30.6 --no-cleanup
```

**CI 流水线步骤**：
1. 🔍 前置检查（检测 Docker/Kind/kubectl）
2. 📦 创建多节点 Kind 集群（使用 `kind-cluster.yaml`）
3. 🔎 验证集群状态
4. 📦 使用 `deploy-example.yaml` 部署 Deployment + Service
5. 🌐 端口转发与服务访问测试
6. 📈 扩缩容测试（3 → 5 → 2）
7. 🩹 自愈测试（单 Pod + 批量删除）
8. 🔄 发布回滚测试
9. 🧹 自动清理

---

## 6. 完整部署管理

`setup-k8s-lab.sh` 是功能最完整的统一入口脚本，支持交互式菜单和 CLI 模式。

### 交互式菜单

```bash
sudo bash setup-k8s-lab.sh
```

提供以下菜单选项：
- **1** 📦 一键安装所有依赖
- **2** ☸️ 创建 Kind 集群（支持指定版本）
- **3** 🧪 运行全部功能测试
- **4** 📋 选择单项测试
- **5** 🚀 一键全流程（安装 → 创建 → 测试 → 清理）
- **6** 🔍 环境检测
- **7** 🧹 清理环境

### CLI 模式

```bash
# 一键全流程
sudo bash setup-k8s-lab.sh --all

# 安装依赖
sudo bash setup-k8s-lab.sh --install

# 创建集群（支持指定 K8s 版本）
sudo bash setup-k8s-lab.sh --cluster
sudo bash setup-k8s-lab.sh --cluster kind-ha.yaml     # 使用 HA 配置

# 运行测试
sudo bash setup-k8s-lab.sh --test all
sudo bash setup-k8s-lab.sh --test basic
sudo bash setup-k8s-lab.sh --test scale
sudo bash setup-k8s-lab.sh --test self-heal
sudo bash setup-k8s-lab.sh --test storage
sudo bash setup-k8s-lab.sh --test resource
sudo bash setup-k8s-lab.sh --test canary
sudo bash setup-k8s-lab.sh --test network
sudo bash setup-k8s-lab.sh --test calico         # 独立集群测试

# 环境检测
sudo bash setup-k8s-lab.sh --check

# 清理环境
sudo bash setup-k8s-lab.sh --cleanup
```

### K8s 版本指定

`setup-k8s-lab.sh` 和所有独立脚本都支持通过参数指定 K8s 版本：

```bash
# 可用版本：v1.27.3, v1.28.15, v1.29.10, v1.30.6, v1.31.2 等
./quick-experiment.sh v1.28.15
./local-ci.sh v1.30.6
./canary-rollback.sh v1.31.2
```

> ⚠️ **依赖说明**：以下命令需要安装 `jq` 命令行 JSON 处理器，可通过 `sudo apt install jq -y` 安装。

查看所有可用镜像标签：
```bash
curl -s https://registry.hub.docker.com/v2/repositories/kindest/node/tags?page_size=100 | \
  jq -r '.results[].name' | sort -V
```

---

## 7. 独立测试脚本

### 7.1 金丝雀发布与回滚

```bash
./canary-rollback.sh                          # 默认版本
./canary-rollback.sh v1.28.15                 # 指定 K8s 版本
./canary-rollback.sh v1.30.6 --no-cleanup     # 保留集群
```

流程：
1. 创建 3 节点集群（1CP + 2W）
2. 部署稳定版（nginx:1.25，4 副本）
3. 金丝雀发布（升级到 nginx:1.26）
4. 模拟故障版本（nginx:1.26-perl）
5. 自动回滚到原始版本
6. 验证回滚结果

### 7.2 集群版本升级与回滚

```bash
./cluster-upgrade-rollback.sh                          # 默认 v1.28.15 → v1.31.2
./cluster-upgrade-rollback.sh v1.27.3 v1.31.2          # 指定旧版和新版
./cluster-upgrade-rollback.sh v1.30.6 v1.31.2 --no-cleanup
```

流程：
1. 以旧版本创建多节点集群并部署应用
2. 记录节点信息
3. 销毁旧集群，创建新版本集群（模拟升级）
4. 回滚到旧版本（模拟回滚）
5. 验证回滚后节点状态

---

## 8. Kind 集群配置

项目提供多种 Kind 配置文件，适用于不同场景：

| 配置文件 | 节点数 | 特点 | 用途 |
|---------|--------|------|------|
| `kind-2nodes.yaml` | 1CP + 1W | 轻量 | 资源受限环境（4GB 内存） |
| `kind-cluster.yaml` | 1CP + 3W | 标准 | 日常开发和 CI 测试 |
| `kind-ha.yaml` | 3CP + 2W | HA 高可用 | HA 控制平面测试 |
| `kind-full.yaml` | 1CP + 3W | 端口映射 + 挂载 | 需要暴露服务到宿主机 |
| `kind-calico.yaml` | 1CP + 2W | 禁用默认 CNI | Calico 网络插件测试 |
| `kind-no-cni.yaml` | 1CP + 2W | 禁用默认 CNI | 自定义网络插件实验（Cilium/Flannel 等） |

### 使用示例

```bash
# 标准 4 节点集群
kind create cluster --config kind-cluster.yaml

# HA 高可用集群（3 控制平面 + 2 Worker）
kind create cluster --config kind-ha.yaml

# 轻量 2 节点集群
kind create cluster --config kind-2nodes.yaml

# 带端口映射（暴露 8080 → 宿主机）
kind create cluster --config kind-full.yaml

# 禁用 CNI（用于安装 Calico）
kind create cluster --config kind-calico.yaml

# 自定义 CNI 实验
kind create cluster --config kind-no-cni.yaml
```

---

## 9. 手工操作参考

### 9.1 部署示例应用

```bash
kubectl apply -f deploy-example.yaml
```

`deploy-example.yaml` 包含：
- Nginx Deployment（3 副本，含资源限制）
- NodePort Service（暴露端口 80）

### 9.2 集群管理命令

```bash
# 查看节点
kubectl get nodes -o wide

# 查看所有 Pod
kubectl get pods -A

# 端口转发
kubectl port-forward service/nginx 8080:80 &

# 扩容/缩容
kubectl scale deployment nginx --replicas=5
kubectl scale deployment nginx --replicas=2

# 自愈测试
kubectl delete pod -l app=nginx

# 回滚测试
kubectl rollout history deployment/nginx
kubectl rollout undo deployment/nginx --to-revision=1

# 查看集群信息
kubectl cluster-info
```

### 9.3 清理

```bash
# 删除单个集群
kind delete cluster --name k8s-lab

# 删除所有集群
kind get clusters | xargs -n1 kind delete cluster --name

# 清理 Docker 无用资源
docker system prune -f
```

---

## 10. 常见问题

### Docker 镜像拉取慢

```bash
sudo tee /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
sudo systemctl restart docker
```

> ⚠️ **安全提示**：使用第三方镜像站时，镜像的完整性和安全性无法得到官方保证，建议仅用于开发测试环境。生产环境请使用 Docker 官方源或配置自有镜像代理。

### kubectl 连接错误

```bash
kubectl config get-contexts               # 查看所有上下文
kubectl config use-context kind-k8s-lab   # 切换到正确集群
```

### Kind 节点启动失败

```bash
docker --version                                  # 检查 Docker 版本 ≥ 20.10
kind export logs ./kind-logs                      # 导出详细日志
kind delete cluster --name k8s-lab                # 重建集群
kind create cluster --config kind-cluster.yaml
```

### 安装脚本排错

```bash
sudo bash install-docker.sh --check      # Docker 环境检测
sudo bash install-kind.sh --check        # Kind 环境检测
sudo bash install-kubectl.sh --check     # kubectl 环境检测
```

---

## 最佳实践总结

| 你想做什么 | 推荐做法 |
|-----------|---------|
| **5 分钟快速体验** | `./quick-experiment.sh` |
| **CI/CD 模拟测试** | `./local-ci.sh` |
| **完整部署管理** | `sudo bash setup-k8s-lab.sh --all` |
| **应用回滚测试** | `./canary-rollback.sh` |
| **集群升级回滚** | `./cluster-upgrade-rollback.sh` |
| **多版本兼容性** | 脚本后面加版本号参数，如 `./local-ci.sh v1.28.15` |
| **HA 控制平面测试** | `kind create cluster --config kind-ha.yaml` |
| **网络插件实验** | `kind create cluster --config kind-calico.yaml` |
| **日常开发调试** | `kind create cluster --config kind-cluster.yaml` 手动操作 |

---

## 附录：文件结构

```
k8s-lab/
├── install-docker.sh            # Docker 安装/管理脚本
├── install-kind.sh              # Kind 安装/管理脚本
├── install-kubectl.sh           # kubectl 安装/管理脚本
├── setup-k8s-lab.sh             # 完整部署管理脚本（交互式 + CLI）
├── quick-experiment.sh          # 5 分钟快速实验脚本
├── local-ci.sh                  # 本地 CI/CD 模拟脚本
├── canary-rollback.sh           # 金丝雀发布回滚测试脚本
├── cluster-upgrade-rollback.sh  # 集群版本升级回滚模拟脚本
├── deploy-example.yaml          # Deployment + Service 示例配置
├── Makefile                     # 一键管理入口
├── kind-2nodes.yaml             # 2 节点轻量集群配置
├── kind-calico.yaml             # Calico CNI 测试配置
├── kind-cluster.yaml            # 标准 4 节点集群配置
├── kind-full.yaml               # 端口映射 + 挂载配置
├── kind-ha.yaml                 # HA 高可用集群配置
├── kind-no-cni.yaml             # 自定义 CNI 配置
├── k8s-lab.md                   # 本文档
├── README.md                    # 项目简介
└── SYSTEM-IMPACT.md             # 系统影响说明
```

---

*文档维护说明：Kind 版本请参考 https://github.com/kubernetes-sigs/kind/releases，K8s 版本镜像标签请参考 https://hub.docker.com/r/kindest/node/tags。*
