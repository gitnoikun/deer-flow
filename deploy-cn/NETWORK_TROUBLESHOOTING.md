# DeerFlow 国内网络问题排查手册

本手册专治「在国内 Linux 服务器拉不全 Docker 镜像」的问题。按优先级从最常用到
最兜底排列。遇到错误粘贴给我即可，我会据此给出下一步。

---

## 0. 先跑一个诊断脚本

在服务器上执行：

```bash
# 逐个测试关键资源的可达性
for u in \
  "https://registry-1.docker.io/v2/" \
  "https://ghcr.io/v2/" \
  "https://deb.nodesource.com" \
  "https://pypi.org/simple" \
  "https://registry.npmjs.org" \
  "https://enterprise-public-cn-beijing.cr.volces.com/v2/" ; do
  echo "--- $u"
  curl -sS -o /dev/null -w "HTTP %{http_code}  time %{time_total}s\n" --connect-timeout 8 "$u" || echo "  × 连接失败/超时"
done
```

根据输出判断：
- `registry-1.docker.io` 失败 → 必须配 **registry-mirrors** 或代理
- `ghcr.io` 失败 → **registry-mirrors 帮不上**（不在 Docker Hub），必须配代理
- `deb.nodesource.com` 失败 → 构建后端镜像到 Node.js 一步会挂，需代理
- `pypi.org` / `registry.npmjs.org` 失败 → 用 `.env` 里的镜像源即可，不一定需要代理
- `enterprise-public-cn-beijing...` 失败 → **沙箱镜像拉不到**，建议用本地沙箱

---

## 1. 镜像分层与对应的解决方案

DeerFlow 构建要拉三层东西，依赖关系不同，`registry-mirrors` 只解决最内层：

| 层 | 内容 | 谁能解决 | 推荐来源 |
|----|------|---------|---------|
| ① 基础镜像 | `node:22-alpine`、`python:3.12-slim`、`redis:7-alpine`、`nginx:alpine`、`docker:cli` | **registry-mirrors**（Docker Hub） | daocloud / 阿里云个人加速 |
| ② 海外仓库镜像 | `ghcr.io/astral-sh/uv:0.11.1`（uv 运行时） | **仅代理**，registry-mirrors 无效 | 给 daemon 配 `proxies` |
| ③ 容器内联网下载 | nodesource apt、pypi、npm 装 lark-cli | ①镜像源（pypi/npm）+ ②代理（nodesource） | `UV_INDEX_URL`/`NPM_REGISTRY` + 代理 |

**结论**：只配 registry-mirrors 往往不够，因为 `uv` 在 ghcr.io 上。一个能访问 ghcr 的
**HTTP 代理**是最稳的单一方案。

---

## 2. 方案 A：仅配 Registry 镜像加速（最简单，但救不了 ghcr）

适合：服务器能直连 Docker Hub、只是慢，或只缺部分镜像。

编辑 `/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://docker.nju.edu.cn"
  ]
}
```

```bash
sudo systemctl restart docker
```

然后用我提供的脚本一键完成：`./deploy-cn/docker-daemon-setup.sh --mirrors '["https://docker.m.daocloud.io","https://docker.nju.edu.cn"]'`

> 注意：`dockerproxy.com`、`docker.nju.edu.cn` 等第三方公开加速器随时可能失效或限流，
> 稳定体验建议用阿里云个人镜像加速（见下）。

### 阿里云个人镜像加速（推荐长期用）

1. 登录 https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
2. 每个实例有一个专属加速地址，形如 `https://xxxx.mirror.aliyuncs.com`
3. 把它填入 `registry-mirrors` 第一项即可。

---

## 3. 方案 B：Docker daemon 配代理（救 ghcr，最稳）

适合：服务器能访问一个境外/中转 HTTP(S) 代理，或者你有一个能出去的网络通道。
这是解决 `ghcr.io`、`deb.nodesource.com` 等**非 Docker Hub 下载**的唯一通用办法。

编辑 `/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.nju.edu.cn"
  ],
  "proxies": {
    "http-proxy": "http://your-proxy-host:port",
    "https-proxy": "http://your-proxy-host:port",
    "no-proxy": "localhost,127.0.0.1,gateway,frontend,nginx,redis,provisioner"
  }
}
```

```bash
sudo systemctl restart docker
```

一键脚本：

```bash
./deploy-cn/docker-daemon-setup.sh \
  --proxy-http  "http://your-proxy-host:port" \
  --proxy-https "http://your-proxy-host:port"
```

> **关键**：Docker 的 `proxies` 只作用于 **daemon 拉镜镜像**这一步（registry 下载），
> **不会**给容器内运行时的网络做代理。容器内（如 gateway 里跑 agent、LLM 调用）
> 需要代理的话，要在 `.env` 里设 `HTTP_PROXY` / `HTTPS_PROXY`（compose 会注入容器）。

---

## 4. 方案 C：容器内运行时的代理（如果 agent 也要联网）

`.env` 里加上（compose 已能从根 `.env` 注入到容器）：

```
HTTP_PROXY=http://your-proxy-host:port
HTTPS_PROXY=http://your-proxy-host:port
NO_PROXY=localhost,127.0.0.1,gateway,frontend,nginx,redis,provisioner,host.docker.internal
```

> 但要注意：`docker-compose.yaml` 里 `gateway` 的 env_file 是 `../.env`，所以根 `.env`
> 的 `HTTP_PROXY` 等会进入 gateway 容器。**模型 API 请求**如果走国内可直连的 base_url
> （如 deepseek、volcengine），其实不需要代理，反而代理会拖慢或中断。

---

## 5. 字节沙箱镜像（你之前拉不到的那个）

镜像地址：
`enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0`

这个在**火山引擎公开仓库**，不在 Docker Hub，`registry-mirrors` 解决不了。

### 5.1 最省事：本轮先不用它（推荐）

用我给你的 `config.local.yaml`（本地沙箱模式），**完全不拉这个镜像**，直接能跑。

```bash
cp deploy-cn/config.local.yaml config.yaml
./deploy-cn/deploy.sh
```

### 5.2 想用真沙箱：先确认网络能否到达火山仓库

```bash
docker pull enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0
```

能拉到就换 `config.aio.yaml`：

```bash
cp deploy-cn/config.aio.yaml config.yaml
./deploy-cn/deploy.sh
```

### 5.3 拉到镜像但很慢 / 部分失败：预先用能拉到的机器拉镜像

在一台能访问该仓库的机器上：

```bash
docker pull enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0
docker save enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:1.11.0 -o sandbox-image.tar
scp sandbox-image.tar user@server:/path/to/deer-flow/
```

在服务器上：

```bash
docker load -i sandbox-image.tar
```

之后再启动，`config.yaml` 里 `sandbox.image` 指向这个 tag 即可，本地已有镜像不再重复拉。

---

## 6. 构建期常见错误对照表

| 报错 | 原因 | 解决 |
|------|------|------|
| `pull access denied for ghcr.io/astral-sh/uv` | 无法访问 ghcr | daemon 配代理（方案 B）|
| `dial tcp ... i/o timeout` 拉基础镜像 | Docker Hub 慢/断 | registry-mirrors（方案 A）|
| `denied: requested access to the resource is denied` | 拉私有仓库/无权限 | 检查镜像名，或用公共镜像 |
| `E: Failed to fetch ... nodesource` | nodesource apt 源连不上 | 代理（方案 B）|
| `npm ERR! network` / `ETIMEDOUT` | npm 拉包失败 | `.env` 设 `NPM_REGISTRY=https://registry.npmmirror.com` |
| `Error: Cannot find module pnpm` | 前端 corepack 下载 pnpm 失败 | 代理 / `NPM_REGISTRY` |
| `uv ... error: Index URL ... network` | pypi 拉依赖失败 | `.env` 设 `UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple` |
| `unknown flag: --wait` | Compose 版本过旧 | `sudo apt-get install -y docker-compose-plugin` |
| `gateway unhealthy / healthcheck failed` | 容器内启动失败 | 看 `logs gateway`；多数是 config.yaml 模型配置问题 |

---

## 7. 验证清单（都通过才算网络 OK）

```bash
docker pull hello-world                    # Docker Hub 可达（registry-mirrors 生效）
docker pull ghcr.io/astral-sh/uv:0.11.1   # ghcr 可达（需代理）
docker run --rm node:22-alpine node -v     # 能拉到 node 基础镜像 + 运行
docker run --rm python:3.12-slim python -V # 能拉到 python 基础镜像 + 运行
```

---

## 8. 一个常见的「假成功」陷阱

有人配了 `registry-mirrors` 后，`docker pull ghcr.io/...` 仍在 `registry-1.docker.io`
镜像层中间失败。原因是：**registry-mirrors 不会转发光 ghcr/其它 registry**。所以判断
「网络是否 OK」必须**逐个测试 ghcr.io**，而不是只看 Docker Hub 的 hello-world。

---

把任何一条命令的报错贴给我，我会帮你定位并给出对应的修改。
