# 部署 k8s-lab 对系统的全部影响分析文档

> **版本**：1.1  
> **更新日期**：2026-05-08  
> **适用环境**：Ubuntu 22.04 LTS（主要支持），其他 Linux 发行版可能部分兼容  
> **用途**：帮助用户充分了解部署 k8s-lab 实验环境对宿主机系统的所有影响

---

## 目录

1. [概述](#1-概述)
2. [核心影响：系统软件变更](#2-核心影响系统软件变更)
3. [核心影响：系统配置变更](#3-核心影响系统配置变更)
4. [核心影响：系统资源消耗](#4-核心影响系统资源消耗)
5. [核心影响：网络变更](#5-核心影响网络变更)
6. [核心影响：存储变更](#6-核心影响存储变更)
7. [核心影响：安全与权限](#7-核心影响安全与权限)
8. [核心影响：服务与进程](#8-核心影响服务与进程)
9. [各组件卸载后的残留](#9-各组件卸载后的残留)
10. [对生产环境的影响评估](#10-对生产环境的影响评估)
11. [常见问题与缓解措施](#11-常见问题与缓解措施)
12. [影响速查表](#12-影响速查表)

---

## 1. 概述

### 1.1 项目简介

k8s-lab 是一个基于 Kind（Kubernetes in Docker）的单物理机 Kubernetes 实验环境。它由以下组件构成：

| 组件 | 版本（示例） | 用途 |
|------|-------------|------|
| **Docker Engine** | ≥ 24.0 | 容器运行时，Kind 的基础依赖 |
| **Kind** | ≥ v0.24.0 | 在 Docker 容器中运行 Kubernetes 节点 |
| **kubectl** | ≥ v1.28 | Kubernetes 命令行管理工具 |
| **Kubernetes** | ≥ v1.28（由 Kind 提供） | 容器编排平台 |

### 1.2 设计原则

本项目遵循 **"零物理机侵入"** 设计原则：

- **容器化部署**：K8s 节点全部运行在 Docker 容器中，不直接修改物理机的 K8s 配置
- **一键清理**：删除 Kind 集群即可恢复环境，脚本化卸载无残留
- **不修改内核参数**：不关 swap、不调内核参数（对比传统 kubeadm 部署）
- **标准 K8s 兼容**：使用标准 Kubernetes 组件，与生产环境行为一致

---

## 2. 核心影响：系统软件变更

### 2.1 安装的软件包

#### Docker Engine（通过 install-docker.sh 安装）

| 包名 | 来源 | 说明 | 是否可卸载 |
|------|------|------|-----------|
| `docker-ce` | Docker 官方 APT 仓库 | Docker 引擎 | ✅ 是 |
| `docker-ce-cli` | Docker 官方 APT 仓库 | Docker 命令行工具 | ✅ 是 |
| `containerd.io` | Docker 官方 APT 仓库 | 容器运行时 | ✅ 是 |
| `docker-buildx-plugin` | Docker 官方 APT 仓库 | Docker Buildx 多架构构建插件 | ✅ 是 |
| `docker-compose-plugin` | Docker 官方 APT 仓库 | Docker Compose 插件 | ✅ 是 |

**间接依赖**（由脚本自动安装）：

| 包名 | 用途 |
|------|------|
| `ca-certificates` | SSL/TLS 证书支持 |
| `curl` | 网络请求工具 |
| `gnupg` | GPG 密钥管理（用于验证 Docker 包签名） |
| `lsb-release` | Linux 发行版信息 |
| `bash-completion` | 命令行自动补全（可选，用于 kubectl） |

#### Kind（通过 install-kind.sh 安装）

| 文件 | 位置 | 说明 |
|------|------|------|
| `kind` 二进制 | `/usr/local/bin/kind` | Kind 命令行工具 |

#### kubectl（通过 install-kubectl.sh 安装）

| 文件 | 位置 | 说明 |
|------|------|------|
| `kubectl` 二进制 | `/usr/local/bin/kubectl` | Kubernetes 命令行工具 |
| 自动补全配置（可选） | `/etc/bash_completion.d/kubectl` | Bash 自动补全 |
| 自动补全配置（可选） | `/usr/local/share/zsh/site-functions/_kubectl` | Zsh 自动补全 |

### 2.2 新增的 APT 源

**文件位置**：`/etc/apt/sources.list.d/docker.list`

**内容示例**：
```
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable
```

**影响**：
- APT 更新时（`apt update`）会从 Docker 官方源拉取元数据
- 可获取 Docker 官方包的最新更新
- 网络受限环境下可能导致 `apt update` 变慢

### 2.3 新增的 GPG 密钥

**文件位置**：`/etc/apt/keyrings/docker.asc`

**用途**：验证 Docker 官方 APT 仓库的包签名

### 2.4 备份文件

安装脚本在更新现有工具时会创建备份：

| 备份文件 | 说明 |
|----------|------|
| `/usr/local/bin/kind.bak.YYYYMMDD-HHMMSS` | Kind 旧版本备份 |
| `/usr/local/bin/kubectl.bak.YYYYMMDD-HHMMSS` | kubectl 旧版本备份 |

---

## 3. 核心影响：系统配置变更

### 3.1 用户组变更

**新增组**：`docker`

**影响**：
- 属于 `docker` 组的用户无需 `sudo` 即可执行 `docker` 命令
- 这等同于拥有 **root 级别权限**（Docker 容器可以挂载宿主机文件系统、访问网络等）

**缓解措施**：
- 仅将可信用户加入 `docker` 组
- 使用 `sudo` 运行 Docker 命令可避免此风险

### 3.2 服务配置

| 配置项 | 变更内容 | 位置 |
|--------|---------|------|
| Docker 开机自启 | `systemctl enable docker` | systemd 配置 |
| Docker 守护进程 | 默认配置 | `/etc/docker/daemon.json`（仅当用户自行配置时才存在） |
| Docker 网络 | `docker0` 网桥 | 内核网络栈 |

**Docker daemon.json**（默认不存在，仅当用户配置镜像加速器时创建）：
```json
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
```

### 3.3 内核参数

**本项目不修改任何内核参数**。这是与传统 kubeadm 部署方式的关键区别。

对比传统 kubeadm 部署所需的内核参数调整：

| 参数 | kubeadm 要求 | Kind 方案 | 本项目的做法 |
|------|-------------|-----------|------------|
| `net.bridge.bridge-nf-call-iptables` | 必须 = 1 | 不需要 | **不修改** |
| `net.ipv4.ip_forward` | 必须 = 1 | 不需要 | **不修改** |
| `net.ipv4.conf.all.rp_filter` | 可能需要调整 | 不需要 | **不修改** |
| `vm.swappiness` | 可能需要 = 0 | 不需要 | **不修改** |
| 关闭 swap | 强烈建议 | 不需要 | **不修改** |

### 3.4 环境变量

安装脚本不修改 `/etc/environment`、`~/.bashrc` 或 `~/.zshrc` 文件。

唯一可能的变化：
- 如果启用 kubectl 自动补全，会自动配置 shell 补全文件

---

## 4. 核心影响：系统资源消耗

### 4.1 磁盘空间

#### 安装占用

| 组件 | 占用空间（约） |
|------|---------------|
| Docker Engine + containerd | 300-500 MB |
| Kind 二进制 | 10-15 MB |
| kubectl 二进制 | 50-80 MB |
| APT 缓存 | 100-200 MB（`apt-get install` 临时占用） |
| **合计（仅工具）** | **~500-800 MB** |

#### 运行占用

| 资源 | 4 节点集群（1CP+3W） | 2 节点集群（1CP+1W） |
|------|---------------------|---------------------|
| Docker 镜像（Kind 节点镜像） | ~600 MB × 4 = 2.4 GB | ~600 MB × 2 = 1.2 GB |
| Docker 镜像（Nginx 等） | ~200 MB | ~200 MB |
| 容器磁盘（每个节点） | ~1-2 GB（overlay2 分层存储） | ~1 GB |
| 容器日志 | 持续增长（默认 10MB/个） | 持续增长 |
| **合计（运行中）** | **~4-6 GB** | **~2-3 GB** |

#### 临时文件

| 位置 | 用途 | 大小 |
|------|------|------|
| `/tmp/k8s-lab-setup-*.log` | 安装/测试日志 | 几十 KB |

#### 镜像缓存

| 镜像 | 大小 | 说明 |
|------|------|------|
| `kindest/node:v1.31.2` | ~600 MB | K8s 节点镜像（每版本） |
| `nginx:alpine` | ~7 MB | 测试用应用镜像 |
| `nginx:1.25` / `nginx:1.26` | ~190 MB | 回滚测试用 |
| `progrium/stress` | ~5 MB | 资源压力测试 |
| `hello-world` | ~13 KB | Docker 验证测试 |

### 4.2 内存消耗

| 场景 | 内存占用 | 说明 |
|------|---------|------|
| 仅安装工具（无集群） | ~500 MB | Docker 守护进程常驻 |
| 1 控制平面 + 1 Worker | ~1.5-2 GB | 轻量模式 |
| 1 控制平面 + 3 Worker（推荐） | ~3-4 GB | 标准测试模式 |
| 3 控制平面 + 2 Worker（HA） | ~5-7 GB | 高可用模式 |

**各 K8s 组件内存分布**（1 个控制平面约 500-800 MB）：

| 组件 | 内存（约） |
|------|-----------|
| kube-apiserver | 200-400 MB |
| etcd | 100-200 MB |
| kube-controller-manager | 50-100 MB |
| kube-scheduler | 30-50 MB |
| kubelet（每个节点） | 50-100 MB |
| CoreDNS（1-2 副本） | 20-40 MB |
| 运行 Pod（测试应用） | 额外占用 |

### 4.3 CPU 消耗

| 场景 | CPU 占用 | 说明 |
|------|---------|------|
| 空闲状态（无工作负载） | 低（< 5% 单核） | 依赖 Docker/K8s 组件开销 |
| 创建集群时 | 中高（50-100% 单核） | 拉取镜像、启动容器 |
| 运行测试时 | 中（20-50% 单核） | port-forward、curl 等操作 |
| 运行资源压力测试时 | 高（取决于 `stress` 参数） | 由 `progrium/stress` 主动压测 |

### 4.4 资源下限评估

**要稳定运行 4 节点集群的最低配置**：

| 资源 | 最低 | 建议 |
|------|------|------|
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 16 GB |
| 磁盘 | 20 GB | 40 GB SSD |
| /var/lib/docker 可用 | 10 GB | 20 GB |

**低于最低配置时的缓解措施**：
- 使用 `kind-2nodes.yaml`（仅 1 控制平面 + 1 Worker）
- 减少测试副本数
- 定期执行 `docker system prune -f` 清理缓存

---

## 5. 核心影响：网络变更

### 5.1 Docker 网络

| 网络名称 | 类型 | 子网（默认） | 说明 |
|----------|------|-------------|------|
| `docker0` | bridge | 172.17.0.0/16 | Docker 默认网桥 |
| `kind` | bridge | 动态分配 | Kind 创建的节点网络 |

**影响**：
- Docker 会在宿主机创建多个虚拟网络接口
- `kind` 会为每个集群创建独立的 Docker 网络
- 每个 Kind 节点容器会获得一个内部 IP

### 5.2 Kind 集群网络

**每个 Kind 集群创建的内容**：

| 资源 | 示例 | 说明 |
|------|------|------|
| Docker 网络 | `kind` | 集群节点互联 |
| 容器 | `k8s-lab-control-plane` | 控制平面节点 |
| 容器 | `k8s-lab-worker`、`k8s-lab-worker2` 等 | Worker 节点 |
| 端口映射 | 6443 → 宿主机随机端口 | API Server 暴露 |

### 5.3 端口占用

#### 必须端口

| 端口 | 协议 | 组件 | 说明 |
|------|------|------|------|
| 6443（Kind 节点内） | TCP | kube-apiserver | K8s API 端口，映射到宿主机随机端口 |
| 8443/TCP（节点内） | TCP | kube-apiserver（内部） | K8s API 内部通信 |
| 10250/TCP（节点内） | TCP | kubelet | Kubelet API |
| 2379-2380/TCP（节点内） | TCP | etcd | etcd 客户端/对等通信 |

> **注意**：以上端口在 Kind 节点容器内监听，**一般不直接暴露到宿主机**。  
> 宿主机上仅占用 Kind 映射的随机宿主机端口（可通过 `docker port` 查看）。

#### 可选端口（当使用端口映射配置时）

| 宿主机端口 | 用途 | 配置方式 |
|-----------|------|---------|
| 8080/TCP | Nginx 测试服务 | port-forward / extraPortMappings |
| 8443/TCP | HTTPS 测试服务 | extraPortMappings |
| 30080/TCP | NodePort 服务 | extraPortMappings |

### 5.4 DNS 影响

- Docker 和 Kind 使用宿主机 DNS 配置（`/etc/resolv.conf`）
- Kind 集群内部的 CoreDNS 负责 K8s 服务发现
- **宿主机 DNS 配置不受影响**

### 5.5 防火墙/iptables 影响

Docker 会自动管理 iptables 规则：

| 规则 | 说明 |
|------|------|
| FORWARD 链 | Docker 添加 ACCEPT 规则允许容器间通信 |
| NAT 规则 | 端口映射和容器出网 NAT |
| DOCKER 链 | Docker 自定义链 |

**影响**：
- 如果宿主机有严格的 iptables 策略，Docker 的自动规则可能与之冲突
- 删除所有容器和网络后，Docker 会自动清理其 iptables 规则
- 部分 iptables 规则（如 DOCKER 链）可能在 Docker 卸载后残留

---

## 6. 核心影响：存储变更

### 6.1 Docker 存储

| 目录 | 用途 | 说明 |
|------|------|------|
| `/var/lib/docker` | Docker 主存储 | 镜像、容器、卷、构建缓存 |
| `/var/lib/docker/overlay2` | 容器分层存储 | 每个容器的读写层 |
| `/var/lib/docker/image` | 镜像元数据 | 镜像层索引和配置 |
| `/var/lib/docker/volumes` | Docker 卷 | 持久化存储卷 |
| `/var/lib/docker/containers` | 容器配置和日志 | 每个容器的 JSON 日志 |
| `/var/lib/docker/buildkit` | BuildKit 缓存 | Docker 构建缓存 |

### 6.2 Kind 节点存储

每个 Kind 节点容器内部使用：

| 路径 | 用途 | 持久性 |
|------|------|--------|
| `/var/lib/kubelet` | Kubelet 数据 | 容器删除后消失 |
| `/var/lib/etcd` | etcd 数据（控制平面） | 容器删除后消失 |
| `/var/log/pods` | Pod 日志 | 容器删除后消失 |

### 6.3 Kubernetes 对象持久化

Kind 集群中的 K8s 资源（Deployment、Service 等）存储在 etcd 中，位置在 Kind 节点容器内部，**不直接持久化在宿主机硬盘上**。

### 6.4 宿主机挂载（可选）

使用 `extraMounts` 配置（如 `kind-full.yaml`）时，宿主机目录会被挂载到 Kind 节点容器中：

```yaml
- role: worker
  extraMounts:
    - hostPath: /home/${USER}/k8s-data
      containerPath: /mnt/k8s-data
```

**影响**：宿主机 `/home/${USER}/k8s-data` 目录会被 Kind 节点容器读写

---

## 7. 核心影响：安全与权限

### 7.1 Docker 的安全影响

**将用户加入 docker 组 = 赋予 root 权限**

这是一个广泛认知的安全事项。属于 `docker` 组的用户可以：

- 访问宿主机文件系统（通过挂载）
- 获得网络访问权限
- 执行任意命令（通过容器）
- 绕过系统权限控制

**等效命令**（属于 docker 组的用户可以做到）：
```bash
docker run -v /:/host -it ubuntu bash
# 然后在容器中: chroot /host 获得宿主机 root shell
```

### 7.2 容器安全上下文

| 安全特性 | 默认配置 | 说明 |
|----------|---------|------|
| 容器用户 | root（默认） | Kind 节点容器以 root 运行 |
| 容器特权 | 无特权 | 默认无 `--privileged` 标志 |
| 容器能力 | 部分 | 如 NET_ADMIN（用于网络插件） |
| seccomp | 默认 | 默认 seccomp 配置文件 |
| AppArmor | 默认 | 默认 AppArmor 配置文件 |

### 7.3 网络暴露面

| 暴露面 | 风险级别 | 说明 |
|--------|---------|------|
| Docker API（/var/run/docker.sock） | ⚠️ 高 | 有访问权限者可控制 Docker |
| K8s API Server | ⚠️ 中 | Kind 集群 API 默认仅监听在容器内 |
| NodePort 服务 | ⚠️ 中 | 仅在配置端口映射时暴露 |
| Calico/其他 CNI | ⚠️ 低 | 需要额外安装，有相关安全配置 |

### 7.4 日志审计

| 组件 | 日志位置 | 日志内容 |
|------|---------|---------|
| Docker 守护进程 | `journalctl -u docker` | 容器启动/停止/错误 |
| Docker 容器日志 | `/var/lib/docker/containers/*/` | 容器 stdout/stderr |
| Kind 节点日志 | `kind export logs ./dir` | K8s 组件日志 |
| kubectl 配置 | `~/.kube/config` | 集群连接凭据 |

> **注意**：`~/.kube/config` 包含集群的 CA 证书和管理员凭据，应妥善保管。

---

## 8. 核心影响：服务与进程

### 8.1 新增的系统服务

| 服务名 | 状态 | 说明 |
|--------|------|------|
| `docker.service` | 启用（enabled，开机自启） | Docker 守护进程 |
| `docker.socket` | 启用 | Docker socket 激活 |
| `containerd.service` | 启用 | containerd 容器运行时 |

### 8.2 新增的进程

运行 4 节点 Kind 集群时新增进程概览（约 30-50 个进程）：

```
# 宿主机进程
dockerd                    # Docker 守护进程（1 个）
containerd                 # containerd（1 个）

# Kind 节点（每个节点为 1 个 Docker 容器）
# 每个 Kind 节点内部运行：
kubelet                    # 节点代理
containerd-shim            # 容器运行时
pause                      # Pod 沙箱容器
kube-apiserver             # API 服务器（仅控制平面）
etcd                       # 键值存储（仅控制平面）
kube-controller-manager    # 控制器管理器（仅控制平面）
kube-scheduler             # 调度器（仅控制平面）
coredns                    # DNS 服务
kube-proxy                 # 网络代理

# 测试应用
nginx                      # 测试 Pod
stress                     # 资源压力测试 Pod（运行时）
```

### 8.3 进程资源限制

所有 Kind 节点进程默认无 cgroup 限制。如需限制，可在创建集群时通过 Kind 配置指定：

```yaml
# 不直接支持，但可以通过 Docker 容器限制间接实现
# 例如使用 docker update 限制节点容器
docker update --memory 2G --cpus 2 <container-name>
```

---

## 9. 各组件卸载后的残留

### 9.1 Docker 卸载后残留

| 残留项 | 位置 | 是否自动清理 |
|--------|------|-------------|
| APT 源文件 | `/etc/apt/sources.list.d/docker.list` | ✅ 是 |
| GPG 密钥 | `/etc/apt/keyrings/docker.asc` | ✅ 是 |
| Docker 数据 | `/var/lib/docker` | ⚠️ 可选（卸载时询问） |
| containerd 数据 | `/var/lib/containerd` | ⚠️ 可选（卸载时询问） |
| 用户组 | `docker` 组 | ❌ 不清除 |
| iptables 规则 | DOCKER 链 | ❌ 可能残留 |
| Docker 网络 | `docker0`/`kind` 网桥 | ⚠️ 重启后清除 |
| 日志 | `/var/lib/docker/containers/*/` | ⚠️ 随数据目录清除 |

### 9.2 Kind 卸载后残留

| 残留项 | 位置 | 是否自动清理 |
|--------|------|-------------|
| Kind 集群 | 正在运行的集群 | ❌ 提示但不强制删除 |
| 备份文件 | `/usr/local/bin/kind.bak.*` | ⚠️ 可选（卸载时询问） |

### 9.3 kubectl 卸载后残留

| 残留项 | 位置 | 是否自动清理 |
|--------|------|-------------|
| 备份文件 | `/usr/local/bin/kubectl.bak.*` | ⚠️ 可选（卸载时询问） |
| 自动补全配置 | `/etc/bash_completion.d/kubectl` | ⚠️ 可选（卸载时询问） |
| 自动补全配置 | `/usr/local/share/zsh/site-functions/_kubectl` | ⚠️ 可选（卸载时询问） |
| kubeconfig | `~/.kube/config` | ❌ 不清除（可能包含其他集群配置） |

### 9.4 手动清理残留

```bash
# 删除 docker 组（谨慎）
sudo groupdel docker || true

# 清理残留 iptables 规则
sudo iptables -P FORWARD ACCEPT
sudo iptables -F DOCKER 2>/dev/null || true
sudo iptables -X DOCKER 2>/dev/null || true
sudo iptables -t nat -F DOCKER 2>/dev/null || true
sudo iptables -t nat -X DOCKER 2>/dev/null || true

# 清理 kubeconfig（仅保留其他集群配置）
# 手动编辑 ~/.kube/config 删除 Kind 集群上下文

# 清理 Kind 网络
docker network prune -f
```

---

## 10. 对生产环境的影响评估

### 10.1 适合的场景

- ✅ **个人学习实验**
- ✅ **CI/CD 流水线测试**（在 CI 运行器中）
- ✅ **本地开发调试**
- ✅ **应用回滚测试验证**
- ✅ **多版本兼容性测试**
- ✅ **网络/存储功能测试**

### 10.2 不适合的场景

- ❌ **生产环境服务器**（Docker + Kind 会占用大量资源）
- ❌ **运行关键业务应用的机器**（Docker 组权限风险）
- ❌ **低内存机器（< 4GB）**（Kind 集群无法稳定运行）
- ❌ **已部署 kubeadm 集群的机器**（端口可能冲突）
- ❌ **需要裸金属性能的场景**（容器化带来额外开销）

### 10.3 在 CI/CD 运行器中的影响

由于 CI/CD 环境通常是隔离的、用完即弃的运行器，k8s-lab 在此场景中几乎没有长期影响：

| 影响项 | CI/CD 中的情况 |
|--------|---------------|
| 磁盘占用 | 作业结束后运行器被回收 |
| 网络变更 | 作业结束后 iptables 规则清除 |
| 服务注册 | 无（运行器不保留状态） |
| 安全风险 | 低（运行器本身是隔离的） |
| 配置残留 | 无（运行器通常是干净的镜像） |

---

## 11. 常见问题与缓解措施

### 11.1 磁盘空间不足

**症状**：Kind 集群创建失败、Pod 无法调度、Docker pull 失败

**缓解措施**：
```bash
# 1. 清理 Docker 缓存
docker system prune -a --volumes -f

# 2. 清理 APT 缓存
sudo apt-get clean

# 3. 限制容器日志大小（全局配置）
sudo tee /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
sudo systemctl restart docker

# 4. 使用轻量集群（2 节点）
kind create cluster --config kind-2nodes.yaml
```

### 11.2 Docker 守护进程占用大量内存

**症状**：`dockerd` + `containerd` 进程占用 > 1GB 内存

**缓解措施**：
```bash
# 1. 重启 Docker 服务释放缓存
sudo systemctl restart docker

# 2. 限制 Docker 日志文件
# 同上配置 daemon.json

# 3. 清理未使用的对象
docker container prune -f
docker image prune -f
```

### 11.3 网络冲突

**症状**：Docker 网桥与现有网络冲突、端口占用

**缓解措施**：
```bash
# 1. 更改 Docker 默认网桥网段
sudo tee /etc/docker/daemon.json <<EOF
{
  "bip": "10.200.0.1/24",
  "default-address-pools": [
    {"base": "10.201.0.0/16", "size": 24}
  ]
}
EOF
sudo systemctl restart docker

# 2. 检查端口占用
sudo lsof -i :6443
sudo lsof -i :8080

# 3. 更改 Kind 集群的端口映射（在集群配置中指定）
```

### 11.4 性能问题

**症状**：集群操作缓慢、kubectl 响应慢

**缓解措施**：
```bash
# 1. 确保有足够 CPU 和内存
# 2. 减少 Worker 节点数
# 3. 减少运行中的 Pod 数
# 4. 使用 SSD 而非 HDD
# 5. 定期检查 Docker 性能
docker system df
docker stats --no-stream
```

### 11.5 安全问题

**缓解措施**：
```bash
# 1. 审查 docker 组成员
sudo grep docker /etc/group

# 2. 移除不必要的用户
sudo gpasswd -d <username> docker

# 3. 使用 sudo 而非加入 docker 组
# 4. 限制 Docker 资源使用
# 5. 定期更新 Docker 和 Kind 到最新版
```

---

## 12. 影响速查表

### 文件系统变更

| 路径 | 类型 | 新增/修改 | 大小（约） |
|------|------|----------|-----------|
| `/usr/local/bin/docker` | 文件 | 新增 | ~60 MB |
| `/usr/local/bin/kind` | 文件 | 新增 | ~12 MB |
| `/usr/local/bin/kubectl` | 文件 | 新增 | ~60 MB |
| `/etc/apt/sources.list.d/docker.list` | 文件 | 新增 | ~0.1 KB |
| `/etc/apt/keyrings/docker.asc` | 文件 | 新增 | ~3 KB |
| `/var/lib/docker/` | 目录 | 新增 | ~1-10 GB |
| `/var/lib/containerd/` | 目录 | 新增 | ~100-500 MB |
| `/etc/bash_completion.d/kubectl` | 文件 | 可选新增 | ~100 KB |
| `/usr/local/share/zsh/site-functions/_kubectl` | 文件 | 可选新增 | ~100 KB |
| `/etc/docker/daemon.json` | 文件 | 可选新增 | ~0.1 KB |
| `/home/<user>/.kube/config` | 文件 | 可能新增/修改 | ~5 KB/集群 |

### 系统配置变更

| 配置项 | 变更 | 影响范围 |
|--------|------|---------|
| `docker` 用户组 | 新增 | 用户权限 |
| Docker 服务 | 启用 + 开机自启 | 系统服务 |
| containerd 服务 | 启用 + 开机自启 | 系统服务 |
| APT 源 | 新增 Docker 官方源 | 包管理器 |
| iptables 规则 | Docker 自动管理 | 网络防火墙 |
| DNS | 无修改 | - |
| swap | 无修改 | - |
| 内核参数 | 无修改 | - |
| PATH | 无修改 | - |

### 运行时资源占用（标准 4 节点集群）

| 资源 | 占用 | 缓解措施 |
|------|------|---------|
| CPU（空闲） | < 5% | 减少 Worker 数 |
| 内存 | 3-4 GB | 使用轻量集群、增加 RAM |
| 磁盘（工具） | 500-800 MB | - |
| 磁盘（运行时） | 4-6 GB | 定期 prune、使用 SSD |
| 网络接口 | 4-5 个虚拟接口 | - |
| 端口（宿主机） | 1-3 个随机端口 | 配置固定端口映射 |
| iptables 规则 | ~20-30 条 | Docker 自动管理 |
| 进程数 | ~30-50 | 减少集群规模 |

### 卸载后残留清单

| 残留项 | 严重程度 | 是否自动清理 |
|--------|---------|-------------|
| Docker 数据目录 | ⚠️ 中（占空间） | 可选清理 |
| 用户组 | ⚠️ 低（安全） | 需手动清理 |
| iptables 规则 | ⚠️ 低 | 可能残留 |
| kubeconfig | ℹ️ 信息（含凭据） | 需手动清理 |
| 备份文件 | ℹ️ 信息 | 可选清理 |
| 自动补全配置 | ℹ️ 信息 | 可选清理 |

---

## 附录：项目文件清单

```
k8s-lab/
├── install-docker.sh            # Docker 安装/管理
├── install-kind.sh              # Kind 安装/管理
├── install-kubectl.sh           # kubectl 安装/管理
├── setup-k8s-lab.sh             # 统一管理入口
├── quick-experiment.sh          # 5 分钟快速实验
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
└── SYSTEM-IMPACT.md             # 本文档
```

---

## 附录：变更日志

| 日期 | 版本 | 变更内容 |
|------|------|---------|
| 2026-05-08 | 1.1 | 修复安装脚本选项表与实际不符；更新文件清单，补充 Makefile、README.md、kind-no-cni.yaml |
| 2026-05-08 | 1.0 | 初始版本，完整覆盖 k8s-lab 所有组件的影响分析 |

---

*本文档由 k8s-lab 项目自动生成，如有更新请在项目根目录重新生成。*
