# DeerFlow 国内 Linux 服务器部署指南

本文件夹是**独立于官方仓库**的部署辅助包，专门解决在**国内网络环境下**把 DeerFlow
跑起来的两个核心痛点：

1. **构建镜像时要拉取大量海外资源**（`ghcr.io/astral-sh/uv`、`deb.nodesource.com`、
   Docker Hub 基础镜像、npm registry、pypi）——通过镜像源 + 代理兜底解决。
2. **字节的 AIO 沙箱镜像**（`enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0`）
   在公共环境常常拉不到——通过**默认启用本地沙箱（LocalSandboxProvider）**绕开，
   无需拉沙箱镜像即可启动服务。

---

## 一、典型工作流（Windows 改代码 → Linux 跑 Docker）

```
┌────────────┐      git push / pull / copy      ┌───────────────┐
│   Windows   │ ────────────────────────────────▶ │    Linux      │
│  改代码/提交 │        deploy-cn/ 一起推过去       │   git pull    │
└────────────┘                                    │  ./deploy-cn/ │
                                                  │  deploy.sh    │
                                                  └───────────────┘
```

1. **Windows 侧**：在 `d:\work\idea\deer-flow` 改代码、`git commit`、`git push`。
   本 `deploy-cn/` 文件夹会随仓库一起推送（它不包含任何密钥）。
2. **Linux 侧**：`git pull` 拉最新代码 + `deploy-cn/`。
3. **Linux 侧首次部署**（见 `deploy.sh` 或下文详述）。
4. **Windows 继续改代码** → push → Linux `git pull` → 重新 `deploy.sh`。

> **重要**：`deploy-cn/` 里所有 `.sh` 脚本是**给你在 Linux 服务器上手动执行的**，
> 不要 copy 到 Windows 运行（脚本里用到了 bash、docker 等 Linux 环境）。

---

## 二、Linux 服务器前置要求

| 依赖 | 要求 | 说明 |
|------|------|------|
| Docker | 24+，含 Compose v2（`docker compose`） | `deploy.sh` 用 `docker compose` 子命令 |
| Docker daemon | 已配置国内镜像加速或代理（见下文第 5 节） | **必须要**，否则光拉基础镜像就卡住 |
| 磁盘 | ≥ 20 GB 空闲 | 三个镜像加起来 3~4 GB，构建缓存再占几 GB |
| 内存 | ≥ 8 GB（建议 16 GB） | 后端 + 前端 + 构建时临时开销 |
| CPU | ≥ 2 核（建议 4 核） | Docker 构建阶段（尤其前端）吃 CPU |
| Git | 已 clone 仓库且有 `dev` 分支 | 项目需要后端/前端/技能目录结构 |

---

## 三、Linux 侧一次性准备

```bash
# 1. 进入仓库根目录
cd /path/to/deer-flow

# 2. 创建配置文件（.env 提供构建/运行时环境变量）
cp deploy-cn/.env.template .env
vim .env        # 至少填：模型 API Key（如 OPENAI_API_KEY / DEEPSEEK_API_KEY）

# 3. 生成 config.yaml（后端主配置）—— 默认启用本地沙箱，无需沙箱镜像
cp deploy-cn/config.local.yaml config.yaml
vim config.yaml # 检查模型、base_url 等

# 4. 生成 MCP/技能配置（默认空即可）
cp extensions_config.example.json extensions_config.json
#    frontend/.env 由 deploy.sh 自动从 .env.example 兜底生成，无需手动处理
#    （也可手动：cp frontend/.env.example frontend/.env）

# 5.（推荐）配置 Docker 国内镜像加速 —— 见第 5 节
#    最省事做法：先看服务器能否直连 Docker Hub，若不能，用 ./deploy-cn/docker-daemon-setup.sh
```

### 配置文件说明

- **`.env`**：由 `docker-compose.yaml` 通过 `env_file` 读取。里面填写：
  - 模型的 API Key（`OPENAI_API_KEY`、`DEEPSEEK_API_KEY` 等）
  - 各类国内镜像源（`APT_MIRROR`、`PIP_INDEX_URL`、`UV_INDEX_URL`、`NPM_REGISTRY`）
  - 可选：HTTP 代理
  - 注意：这些变量同时也会被 `deploy-cn/deploy.sh` 读取并传给 `docker compose`。

- **`config.yaml`**：后端运行主配置。本部署包默认用 `config.local.yaml`（本地沙箱），
  因为**本地沙箱不需要拉任何 Docker 沙箱镜像**，启动最快。

---

## 四、构建 & 启动

```bash
cd /path/to/deer-flow

# 方式 A：全自动（构建 + 启动 + 等待就绪 + 打印地址）
./deploy-cn/deploy.sh

# 方式 B：分步（先看构建输出，出问题好排查）
./deploy-cn/deploy.sh build     # 只构建镜像
./deploy-cn/deploy.sh start     # 从已构建镜像启动

# 停止
./deploy-cn/deploy.sh down
```

启动成功后访问：`http://<服务器IP>:2026`

> 默认绑定 `127.0.0.1`（仅本机可访问）。若要从其它机器访问，请在 `.env` 里设
> `BIND_HOST=0.0.0.0`。**务必在暴露到公网前完成首次管理员账号创建**，
> 因为 DeerFlow 的 agent 有执行命令的能力。

---

## 五、网络镜像与加速（国内部署的关键）

### 5.1 构建阶段用到的海外源（按出现位置）

| 资源 | 位置 | 可替换镜像源 |
|------|------|-------------|
| **uv 源码镜像** `ghcr.io/astral-sh/uv:0.11.1` | `backend/Dockerfile` 第 7 行 | **不能用镜像源替换**，只能靠 Docker 代理 |
| **Node.js**（nodesource apt） | `backend/Dockerfile` 第 36-39 行 | 同样走 https 下载国外 gpg，靠代理 |
| **Python 依赖（uv sync）** | `backend/Dockerfile` 第 74 行 | `UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple` |
| **npm（lark-cli）** | `backend/Dockerfile` 第 44 行 | `NPM_REGISTRY=https://registry.npmmirror.com` |
| **前端 pnpm/corepack** | `frontend/Dockerfile` | `NPM_REGISTRY=https://registry.npmmirror.com` |
| **deb（apt）** | `backend/Dockerfile` 第 29 行 | `APT_MIRROR=mirrors.aliyun.com`（不带 https://） |
| **基础镜像** `node:22-alpine` 等 | Docker Hub | 靠镜像加速（registry-mirrors） |

### 5.2 推荐做法：三层兜底

**第 1 层：Docker 基础镜像加速** —— 编辑 `/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://docker.nju.edu.cn"
  ]
}
```

然后重启：`sudo systemctl restart docker`。

**第 2 层：公开仓库镜像加速**（ghcr.io 等不在 Docker Hub 上，registry-mirrors 不生效）：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://docker.nju.edu.cn"
  ],
  "insecure-registries": ["ghcr.io"],
  "experimental": true
}
```

> 注意：ghcr.io 的加速各服务提供情况随时变。如果 `docker pull ghcr.io/astral-sh/uv:0.11.1`
> 失败，最稳妥是**给 Docker daemon 配 HTTP/HTTPS 代理**。

**第 3 层（最稳）：Docker daemon 配代理** —— 如果服务器能访问一个境外 HTTP 代理
（或通过国内中转），在 `/etc/docker/daemon.json` 加：

```json
{
  "proxies": {
    "http-proxy": "http://your-proxy-host:port",
    "https-proxy": "http://your-proxy-host:port",
    "no-proxy": "localhost,127.0.0.1,gateway,frontend,nginx,redis"
  }
}
```

可用 `./deploy-cn/docker-daemon-setup.sh` 一键写入配置并重启 Docker。

### 5.3 阿里云个人镜像加速

若你有阿里云账号，登录 [容器镜像服务控制台](https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors)
获取专属加速地址，替换上面的 `registry-mirrors`。

### 5.4 应急：uv / ghcr 实在拉不到时

`ghcr.io/astral-sh/uv:0.11.1` 无法用镜像源替代，若代理也没有，可以在**一台能访问
ghcr 的机器**上手动搬运：

```bash
# 在能访问 ghcr 的机器上
docker pull ghcr.io/astral-sh/uv:0.11.1
docker save ghcr.io/astral-sh/uv:0.11.1 -o uv-image.tar
scp uv-image.tar user@server:/tmp/

# 在目标服务器上，先加载再构建
docker load -i /tmp/uv-image.tar
docker tag ghcr.io/astral-sh/uv:0.11.1 ghcr.io/astral-sh/uv:0.11.1
```

> 若后端镜像的 Node.js（nodesource）下载也失败，可在 `backend/Dockerfile` 中临时
> 注释掉第 36-39 行（会牺牲 lark-cli/部分 MCP 功能），或直接给 Docker daemon 配代理。
> 改动 `backend/Dockerfile` 属于对官方代码的破坏性修改，建议优先用代理。

---

## 六、沙箱模式选择（字节沙箱拉不到怎么办）

DeerFlow 支持多种沙箱（agent 执行命令的隔离环境）。你的核心诉求是**先跑起来**，
所以默认选**本地沙箱**。

### 6.1 本地沙箱（推荐，默认）

`config.local.yaml` 里：

```yaml
sandbox:
  use: deerflow.sandbox.local:LocalSandboxProvider
  allow_host_bash: false
```

- **无需拉任何 Docker 沙箱镜像**，启动最快。
- 缺点：agent 的 bash 命令直接在容器内执行（不隔离）。`allow_host_bash` 默认 `false`，
  已把越界风险降到最低。

### 6.2 AIO 沙箱（字节容器，拉不到）

这是你之前在公共环境失败的那个。配置：

```yaml
sandbox:
  use: deerflow.community.aio_sandbox:AioSandboxProvider
  image: enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0
```

- 镜像在火山引擎公开仓库，**普通网络拉不到**，需要：
  1. 服务器能访问火山引擎仓库，或
  2. 把镜像 export 成一个 tar 在能拉的机器上拉好，再 `docker load` 到服务器。
- 建议先用本地沙箱跑通，隔离需求后面再加。

### 6.3 手动预拉沙箱镜像（如果网络 OK）

```bash
# 从仓库根目录
./scripts/setup-sandbox.sh
```

> 该脚本会按 `config.yaml` 里的 sandbox.image 拉取；若没配置，会拉默认的
> `:1.11.0`。它只是**预拉**，不会自动改 `config.yaml`。

---

## 七、常见错误排查（构建阶段）

### 7.1 `pull access denied` / `connection refused` / `timeout` 拉取 ghcr.io

这是**海外源被墙或超时**。参照第 5 节给 Docker daemon 配代理，或改用能访问
ghcr 的加速（daocloud 等服务）。

### 7.2 `deb.nodesource.com` 超时

后端镜像里要下载 Node.js。这走的是服务器 **容器外网络的 https**，
镜像源（registry-mirrors）帮不上。解决：给 Docker daemon 配代理，
或手动把 Node.js 相关行注释掉（不推荐，会影响 lark-cli）。

### 7.3 npm 装包失败（network）

通过 `NPM_REGISTRY=https://registry.npmmirror.com` 解决。在 `.env` 里配好即可。

### 7.4 pypi 装包失败

通过 `UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple` 解决。

### 7.5 `docker compose` 报 `unknown flag: --wait`

说明 Docker Compose 版本过旧。`deploy.sh` 用了 `--wait`。升级：

```bash
sudo apt-get update && sudo apt-get install -y docker-compose-plugin
```

### 7.6 网关健康检查一直失败（gateway not healthy）

`deploy.sh` 会打印最近 100 行 Gateway 日志。常见原因：
- `config.yaml` 里模型 API Key 没填/填错。
- 镜像里 Python 依赖没装全（看日志里的 ImportError）。

---

## 八、部署后验证

```bash
# 查看服务状态
docker compose -f docker/docker-compose.yaml ps

# 查看 Gateway 日志
docker compose -f docker/docker-compose.yaml logs gateway --tail 100

# 验证网关健康
curl -s http://localhost:8001/health
```

浏览器访问 `http://<服务器IP>:2026`，首次进入会引导你创建管理员账号
（需要填一个模型 API Key 来初始化）。

---

## 九、文件清单

| 文件 | 作用 |
|------|------|
| `deploy.sh` | 主部署脚本（build / start / down） |
| `config.local.yaml` | 后端配置模板（本地沙箱，默认） |
| `config.aio.yaml` | 后端配置模板（AIO 容器沙箱，需拉字节镜像） |
| `config.template.yaml` | **迁移模板**（DeepSeek + Ollama，按当前环境提炼，见 `docs/MIGRATION.md`） |
| `.env.template` | 环境变量模板（镜像源、代理、API Key、NO_PROXY） |
| `docker-daemon-setup.sh` | 一键配置 Docker daemon 镜像加速/代理 |
| `stop.sh` | 停止脚本（等价 `deploy.sh down`） |
| `docs/MIGRATION.md` | **迁移到新服务器的配置清单与说明** |
| `docs/部署指引.md` | 代理版部署指引 |
| `scripts/` | 长期可复用运维脚本（代理/环境/密钥管理等） |
| `README.md` | 本文件 |

> 注意：`.env`、`config.yaml`、`extensions_config.json` 均被官方 `.gitignore`
> 忽略（含密钥），**不要提交**。`deploy-cn/` 下只放模板，不放假密钥。
