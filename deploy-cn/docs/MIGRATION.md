# DeerFlow 迁移到新 Linux 服务器 —— 配置清单与说明

本文档基于**你当前正在运行的服务器环境**（DeepSeek + Ollama，代理走 `192.168.77.10:7897`）
提炼，目标是让你把项目 `git pull` 到**任意一台新 Linux 服务器**后，用最小的改动把它跑起来。

> 前提：新服务器已装好 **Docker 24+ / Docker Compose v2**、**Git**，磁盘 ≥20GB、内存 ≥8GB。

---

## 一、一句话流程

```bash
cd /path/to/deer-flow
cp deploy-cn/.env.template .env                 # ① 填环境变量（镜像源/代理/API Key）
cp deploy-cn/config.template.yaml config.yaml    # ② 填模型（DeepSeek + Ollama 地址）
./deploy-cn/deploy.sh                            # ③ 构建 + 启动
```

---

## 二、需要填的配置（都是环境专属，不能进 git）

### 1. `.env`（从 `deploy-cn/.env.template` 复制）

下面以**当前服务器（192.168.77.10）**为例，`★★★` 标记需要你按新环境修改的项：

| 键 | 当前值 | 迁移时 |
|----|--------|--------|
| `BIND_HOST` | `0.0.0.0` | ★★★ 是否要跨机访问；仅本机可改 `127.0.0.1` |
| `PORT` | `2026` | 一般不变 |
| `HTTP_PROXY` / `HTTPS_PROXY` | `http://192.168.77.10:7897` | ★★★ 换成新环境可达的代理；**没有代理可留空**（看下方第 5 节） |
| `NO_PROXY` | 见下 | ★★★ 若新增内网服务，追加域名；**必须含** `host.docker.internal`（跑本机 Ollama 要用） |
| `APT_MIRROR` | `mirrors.aliyun.com` | 国内默认阿里云，可换清华等 |
| `UV_INDEX_URL` | `https://mirrors.aliyun.com/pypi/simple/` | PyPI 镜像 |
| `PIP_INDEX_URL` | `https://mirrors.aliyun.com/pypi/simple/` | provisioner 用 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像 |
| `DEEPSEEK_API_KEY` | `sk-***` | ★★★ 换成你自己的 key（DeepSeek 那条用的） |
| `UV_EXTRAS` | （空） | 不需要；我们没走 ollama extra |

**`NO_PROXY` 完整示例**（含内网网段 + 镜像域名 + 容器内部主机名）：

```bash
NO_PROXY=localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.aliyun.com,registry.npmmirror.com,*.aliyuncs.com,mirrors.aliyun.com,host.docker.internal
```

> `docker-compose.yaml` 会**自动把 `gateway,frontend,nginx,provisioner,openviking,host.docker.internal` 拼到 `NO_PROXY` 末尾**，
> 所以你只需在 `.env` 里配好**内网网段和镜像域名**那部分即可。但显式写上 `host.docker.internal` 更保险。

---

### 2. `config.yaml`（从 `deploy-cn/config.template.yaml` 复制）

模板里已含 **DeepSeek + 2×Ollama** 三条模型，跟当前服务器一致。迁移时只需确认：

| 项 | 说明 |
|----|------|
| `config_version` | 保持 `36`（模板已写好，别改） |
| `deepseek` 条目 | `base_url` 固定 `https://api.deepseek.com/v1`，`api_key: $DEEPSEEK_API_KEY`（引用 .env）——**跨机器不变** |
| Ollama 条目 `base_url` | **最关键**，二选一：<br>• Ollama 装在【新服务器本机】→ `http://host.docker.internal:11434/v1`（模板默认）<br>• Ollama 还在【别的机器】→ `http://<那台机器内网IP>:11434/v1` |
| Ollama `api_key` | 占位 `ollama` 即可（Ollama 不校验 key，但框架要求非空） |
| `sandbox.use` | `LocalSandboxProvider`（默认，无需拉字节镜像） |

---

## 三、按「Ollama 装在哪」的三种场景

### 场景 A：Ollama 装在新服务器本机（推荐，最独立）
- 在新服务器安装 Ollama，拉模型：`ollama pull qwen3.5:2b`、`ollama pull qwen3.5:0.8b`
- Ollama 默认监听 `127.0.0.1:11434`。**容器内访问宿主要用 `host.docker.internal`**（compose 已配 `extra_hosts` + `NO_PROXY`），无需改监听地址。
- `config.yaml` 里 `base_url: http://host.docker.internal:11434/v1`
- ✅ 依赖 compose 的 `extra_hosts: "host.docker.internal:host-gateway"`，官方 compose 已自带，**不用改**。

### 场景 B：Ollama 仍装在你现在的 Windows（192.168.77.10）那台
- 保证新服务器**能 ping 通** `192.168.77.10`，且那台 Windows Ollama 监听 `0.0.0.0:11434`。
- `config.yaml` 里 `base_url: http://192.168.77.10:11434/v1`
- ⚠️ 若新服务器到 192.168.77.10 不通，或 Windows 防火墙拦了 11434，则不可行。

### 场景 C：完全不用 Ollama（只想跑 DeepSeek）
- `config.yaml` 里**删掉 2、3 两条 Ollama** 即可，DeepSeek 单独就能跑。

---

## 四、新服务器的网络准备（关键，否则卡在拉镜像）

`deploy-cn/README.md` 第 5 节已详述。三句话结论：

1. **Docker 基础镜像加速**（Docker Hub）→ 配 `daemon.json` 的 `registry-mirrors`，或用 `deploy-cn/docker-daemon-setup.sh` 一键配。
2. **ghcr.io 的 uv 镜像**（`ghcr.io/astral-sh/uv:0.11.1`）**不能用镜像源替换**，只能靠 **Docker daemon 代理**。 → 用 `deploy-cn/setup-proxy.sh` 把代理指到可达的 HTTP 代理（如新环境的 `192.168.77.10` 或别的）。
3. 若新服务器**没有代理**：`ghcr.io` 拉不到 → 用 README 5.4 的「手动搬运 uv 镜像 tar」方案。

> 这也是为什么 `.env` 里 `HTTP_PROXY/HTTPS_PROXY` 要随环境改：构建后端镜像时，`deb.nodesource.com` 和 `ghcr.io` 都要靠它。

---

## 五、迁移清单（按顺序执行）

```bash
# 1. 拉代码
git clone <你的仓库> && cd deer-flow && git checkout dev

# 2. 建配置文件
cp deploy-cn/.env.template .env          # 改：代理 / DEEPSEEK_API_KEY / NO_PROXY
cp deploy-cn/config.template.yaml config.yaml   # 改：Ollama base_url
cp extensions_config.example.json extensions_config.json  # 空即可

# 3. 配 Docker 网络（三选一，见第四节）
#   a) 有代理：./deploy-cn/setup-proxy.sh   （把代理指到可达地址）
#   b) 无代理但能访问 Docker Hub：./deploy-cn/docker-daemon-setup.sh  （配镜像加速）
#   c) ghcr 拉不到：见 README 5.4 手动搬运 uv 镜像

# 4. 构建并启动
./deploy-cn/deploy.sh

# 5. 验证
curl -s http://localhost:8001/health    # 期望 200
# 浏览器访问 http://<服务器IP>:2026，首次登录创建管理员
```

---

## 六、常见坑（迁移专门版）

| 现象 | 原因 / 解决 |
|------|------------|
| 构建卡在拉 `ghcr.io/astral-sh/uv` | 该镜像不能走 registry-mirrors，必须配 Docker daemon 代理，或用 `setup-proxy.sh` |
| 启动后 gateway 不健康 | 大概率 `config.yaml` 模型 key 没填 / `$DEEPSEEK_API_KEY` 在 `.env` 里没定义 |
| 选了 Ollama 但 agent 报连接失败 | `config.yaml` 的 `base_url` 没指向 Ollama 实际位置；本机场景必须 `host.docker.internal` 而非 `127.0.0.1` |
| `NO_PROXY` 漏了内网网段 | 服务器到 `192.168.0.0/16` 会被代理，导致内网服务（如宿主 Ollama）连不通 |
| `config_version` 被判过期 | 模板是 36，别改成别的版本号 |

---

## 七、哪些已进 git / 哪些不能进 git

| 类别 | 文件 | 是否提交 |
|------|------|---------|
| 部署入口 | `deploy-cn/deploy.sh`、`stop.sh` | ✅ 已提交 |
| 配置模板 | `deploy-cn/config.template.yaml`、`config.local.yaml`、`config.aio.yaml`、`.env.template` | ✅ 已提交 |
| 文档 | `deploy-cn/docs/MIGRATION.md`、`README.md`、`NETWORK_TROUBLESHOOTING.md` | ✅ 已提交 |
| **真实配置** | **`.env`、`config.yaml`、`extensions_config.json`** | ❌ **gitignore，绝不能提交**（含密钥/服务器专属） |
| 调试产物 | `deploy-cn/diagnostics/`、*.local.log、`config.server.yaml` | ❌ gitignore |
