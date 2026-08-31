# DeerFlow 学习计划

> 目标：理解 DeerFlow（LangGraph-based AI super-agent）的架构，学会如何开发、调试和部署。
> 学习思路：**先跑通（已在服务器跑通）→ 读懂架构 → 动手改一处 → 服务器验证**。
> 本文档配套你在服务器上已运行的实例（nginx `:2026` 可访问）。

---

## 一、先想清楚：本地开发 vs 服务器构建

这是你最关心的问题。先说结论，再讲原因。

### 结论

| 场景 | 推荐做法 |
| --- | --- |
| **日常读代码 / 学架构** | Windows 本地用 IDE（Cursor）看源码，**不需要跑环境** |
| **改代码后想验证效果** | **服务器上验证**（本文档给的流程） |
| **频繁改后端、想快速看效果** | 本地只跑 `Gateway`（`make gateway`，端口 8001）热重载 |

**推荐主路径：Windows 编辑代码 → 提交 Git → 服务器拉取 → 重新构建/重启。**

### 为什么现阶段不推荐在 Windows 本地跑完整环境

本地 `make dev` 需要这些工具，你的 Windows 目前**缺失**：

| 工具 | 状态 | 用途 |
| --- | --- | --- |
| `nginx` | ❌ 未安装 | 反代入口（端口 2026），`make dev` 必需 |
| `uv` | ❌ 未安装 | 后端 Python 环境管理（`uv sync` / `uv run`） |
| `pnpm` | ⚠️ 未启用（有 corepack） | 前端包管理 |
| `python` | ⚠️ 指向 Microsoft Store 别名 | `serve.sh` 明确警告会导致失败，需用 `py` |

装齐这些 + 处理代理/镜像，**成本高、耗时**，且很容易卡在环境上而不是学习上。而**服务器已经是验证过的稳定环境**，改完代码上去验证更省事。

### 什么时候值得装工具在本地跑全套

- 你要**大量高频迭代后端逻辑**，需要毫秒级看到改动效果；或
- 你要**离线开发**、不依赖服务器。

这种情况再装 `uv`、`pnpm`、`nginx`，用 `make dev`。否则不改动就只做代码编辑即可。

---

## 二、学习计划的阶段划分

按"由浅入深、每步可验证"的原则，分为 4 个阶段。

### 阶段 1：先跑通，建立直觉（已完成）

- [x] 服务器 Docker 部署 DeerFlow，浏览器访问 `https://<服务器>:2026` 能对话。
- [x] 确认使用 DeepSeek 模型（`deepseek-v4-flash-vision-exp`），`LocalSandboxProvider`。

**学习要点**：
1. **服务拓扑**：`nginx(2026) → frontend(3000) → gateway(8001) → redis`。入口是 nginx。
2. 打开 `:2026`，新建一个 thread，发消息，观察流式回复。
3. 发一条会触发工具调用的消息，看 agent 怎么用工具（如 `bash`、`ls` 等，本地沙箱）。

**验证**：能对话、能看到工具调用即可。

---

### 阶段 2：读懂架构（核心阶段）

这是最重要的阶段。对应仓库目录，逐个理解：

#### 2.1 后端分层（Harness / App 拆分）
`backend/AGENTS.md` 讲了严格依赖方向：

```
harness (packages/harness/deerflow/)  → 可发布的 agent 框架包，import: deerflow.*
app     (app/)                        → 应用层，FastAPI Gateway + IM 通道，import: app.*
规则：app 可以 import deerflow，deerflow 不能 import app。
```

> ⚠️ **别再一开始就硬啃英文源码**。先读 [TRACE_MAP.md](./TRACE_MAP.md) —— 它把「你发一句话 → 接口 → 各方法调用 → 最终落库」整条链路用 文件名+函数名+一句话 串起来了，你只要跟着这条链路走，就能直观理解 agent 怎么跑起来，再对照 Navicat 里的表验证落库。**看懂链路图后，再按下面目录按需深入。**

**按需深入（先看链路图，再点这里）**：
- `backend/packages/harness/deerflow/agents/` → 核心 agent 系统（`lead_agent/`、`thread_state.py`）
- `backend/packages/harness/deerflow/subagents/` → 子 agent 委派（`executor.py`、`registry.py`）
- `backend/packages/harness/deerflow/sandbox/` → 沙箱执行（`local/`、`tools.py`、`middleware.py`）
- `backend/packages/harness/deerflow/tools/builtins/` → 内置工具
- `backend/packages/harness/deerflow/models/` → 模型工厂（支持 thinking/vision）
- `backend/packages/harness/deerflow/config/` → 配置系统
- `backend/app/gateway/` → FastAPI Gateway（`app.py`、`routers/`）

#### 2.2 请求怎么走（Nginx 路由）
```
/api/langgraph/*  → Gateway 内嵌 agent runtime (8001)，重写为 /api/*
/api/*（其他）     → Gateway REST API (8001)
/  （非 API）      → Frontend (3000)
```

#### 2.3 Agent 运行核心链路
直接看 [TRACE_MAP.md](./TRACE_MAP.md) 的第 2 节「完整链路」，它把 `start_run()` → `run_agent()` →
落到 `runs`/`threads_meta`/`checkpoints`/`run_events` 的每一步都标出来了。不用读源码就能懂。

**验证**：按 TRACE_MAP 第 5 节，发一句话后去 Navicat 查那 4 张表，看到链路每一环确实落了库。
    然后能画出：发请求 → 路由 → service → agent 执行 → 落库 这条主线，并说出每步对应哪个文件。

---

### 阶段 3：动手改一处，服务器验证

选一个**小而真实**的改动，走完"改 → 提交 → 服务器拉取 → 重建/重启 → 验证"闭环。

**推荐几个低风险入手点**（任选其一）：
1. 改 `lead_agent` 的 **system prompt**（在 `backend/packages/harness/deerflow/agents/lead_agent/`），让 agent 换一种说话方式。
2. 加一个**简单的内置工具**（在 `backend/packages/harness/deerflow/tools/builtins/`），模仿现有工具，注册后能在 agent 里调用。
3. 改 `config.yaml` 里的模型参数（temperature、模型名），观察效果。

**改后端代码的服务器验证流程**：

```bash
# 在 Windows（已提交）：
git add -A && git commit -m "feat: 修改 xxx" && git push

# 在服务器（deer-flow 仓库目录）：
git pull
```

再根据改动类型，选择 **重构建** 或 **重启**：

> ⚠️ **所有命令都要在服务器仓库根目录 `/opt/code/deer-flow` 下执行**。`docker compose -f docker/...` 用的是相对路径，跑错目录会解析失败。

- **改了 Python 后端代码** → **重构建 gateway 镜像**（镜像内打包了 `uv sync` 后的代码）：

```bash
cd /opt/code/deer-flow   # 进入服务器仓库根目录
./scripts/deploy.sh build # 重新构建镜像（含 gateway）
docker compose --env-file .env -p deer-flow -f docker/docker-compose.yaml up -d --remove-orphans --wait --wait-timeout 180 gateway
```

- **只改了 `config.yaml` / `extensions_config.json`** → **无需重建，重启 gateway 即可**（config 是挂载的）：

```bash
cd /opt/code/deer-flow
docker compose --env-file .env -p deer-flow -f docker/docker-compose.yaml restart gateway
```

- **改了前端** → 重构建 frontend：

```bash
cd /opt/code/deer-flow
./scripts/deploy.sh build
docker compose --env-file .env -p deer-flow -f docker/docker-compose.yaml up -d --remove-orphans --wait --wait-timeout 180 frontend
```

**验证**：改动生效（重新对话观察）；`make test` 类验证视情况在服务器或本地跑（见阶段 4）。

---

### 阶段 4：测试与质量（进阶）

了解 DeerFlow 的测试体系，能跑、能写基础用例。

- 后端离线测试（不含 live 外部 API 测试）：`cd backend && make test`
- 后端单个测试：`cd backend && python -m pytest tests/test_<feature>.py -q`
- 前端检查：`cd frontend && pnpm check`（lint + typecheck）
- 前端单测：`cd frontend && pnpm test`

> 注意：`make test` 在服务器上需要 Python/uv 环境；若服务器没有，可在本地装 uv 后跑，或只跑 `make test` 验证你改动相关的那几个用例。

---

## 三、常用命令速查（服务器）

| 用途 | 命令（在服务器仓库根目录） |
| --- | --- |
| 构建镜像 | `./scripts/deploy.sh build` |
| 启动（构建+启动） | `./scripts/deploy.sh` |
| 启动（不重建） | `./scripts/deploy.sh start` |
| 停止移除 | `./scripts/deploy.sh down` |
| 看日志 | `docker compose --env-file .env -p deer-flow -f docker/docker-compose.yaml logs -f gateway` |
| 重启 gateway | `docker compose --env-file .env -p deer-flow -f docker/docker-compose.yaml restart gateway` |
| 仅跑后端 Gateway（本地重载） | `cd backend && make gateway`（端口 8001） |

---

## 四、关键概念速记（背下来）

| 概念 | 一句话 |
| --- | --- |
| **Super Agent** | DeerFlow 的"主 agent"，负责规划、调用工具、委派子 agent |
| **Sandbox** | 隔离的执行环境。常用 `LocalSandboxProvider`（本地目录）和 `AioSandboxProvider`（Docker，字节的沙箱镜像） |
| **Subagent** | 主 agent 委派出去并行/后台执行的子任务（`SubagentExecutor`） |
| **MCP** | 外部工具接入协议，在 `extensions_config.json` 里配置 MCP server |
| **Skills** | 技能包，`skills/public/`（提交）和 `skills/custom/`（gitignored） |
| **Memory** | 持久记忆，`deerflow/agents/memory/` |
| **Middleware** | 中间件链（沙箱生命周期、文件上传、视图处理、上下文压缩等） |
| **ThreadState** | 每个会话隔离的状态对象（`thread_state.py`） |

---

## 五、推荐阅读顺序

1. `README.md` / `README_zh.md` — 项目定位、功能
2. `backend/AGENTS.md` — 后端架构（最重要）
3. `frontend/AGENTS.md` — 前端结构
4. `backend/packages/harness/deerflow/agents/` — agent 核心
5. `backend/docs/` — 配置、上传、压缩、评测等专题文档
6. 动手改一个工具 / prompt（阶段 3）

---

## 六、当前现状 & 待办

**已完成**：
- DeerFlow 服务器部署成功，`:2026` 可访问。
- DeepSeek 模型 + `LocalSandboxProvider` 配置就绪。
- 服务器代理、镜像、`uv.lock` 等网络/依赖问题已解决。

**下一步（可选）**：
- [ ] 阶段 2：读懂架构，画架构图
- [ ] 阶段 3：从 system prompt 或一个内置工具入手做第一次改动
- [ ] 若本地要开发：装 `uv`、`pnpm`、`nginx`（或用 `make gateway` 只跑后端）

---

*说明：`deploy-cn/` 内还有其他部署相关文档（如 `部署指引.md`），学习计划与部署指引互补：部署指引管"怎么跑起来"，本计划管"怎么学懂+怎么演进"。*
