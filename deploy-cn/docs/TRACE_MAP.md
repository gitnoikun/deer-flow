# DeerFlow 对话链路地图（从请求到落库）

> 这份文档**不要求你看英文源码**，而是把"你在网页发一句话 → 服务器执行 → 数据落库"整条链路，
> 用**文件名 + 函数名 + 一句话**串起来。你只要跟着这条链路走，就能直观理解 agent 是怎么跑起来的。
> 适合已搭好项目、想搞懂"请求进来之后发生了什么"的人。

---

## 0. 先记住：整个系统分两层

| 层 | 代码目录 | 作用 | 类比 |
|----|---------|------|------|
| **App 层** | `backend/app/` | FastAPI 网关：收 HTTP 请求、鉴权、路由 | 你熟悉的 Controller |
| **Harness 层** | `backend/packages/harness/deerflow/` | agent 框架：真正跑 agent、管理运行、落库 | Service + ORM |

> 依赖方向固定：**App 只能调用 Harness，Harness 不能反向 import App**（有测试强制）。

---

## 1. 你做了什么 → 一次真实的对话请求

你在网页聊天框输入一句话，点发送。前端（Next.js）会做两件事：

1. **POST `/api/threads`** → 新建一个"会话/线程"（thread）
2. **POST `/api/threads/{thread_id}/runs/stream`** → 跑这个 agent，并流式接收回复

下面按**发送消息**展开（第 2 步），这是核心链路。

---

## 2. 完整链路（发送一条消息）

```
[浏览器] 输入"你好"
   │  POST /api/threads/{thread_id}/runs/stream
   ▼
[FastAPI 路由层]  backend/app/gateway/routers/thread_runs.py
   ├─ stream_run()                 ← 接收请求，准备好流式响应
   │     └─ start_run()            ← 核心：创建运行记录 + 启动后台任务
   ▼
[Service 层]  backend/app/gateway/services.py
   └─ start_run()
        ├─ 校验（thread 权限、model 是否在允许列表）
        ├─ run_mgr.create_or_reject()   ← 【落地第 1 张表: runs】
        ├─ record.task = create_task(run_after_metadata(record))
        │      └─ _ensure_thread_metadata()  ← 【落地第 2 张表: threads_meta】
        └─ run_agent(...)                ← 真正执行 agent
   ▼
[执行层]  backend/packages/harness/deerflow/runtime/runs/worker.py
   └─ run_agent()
        ├─ 用 checkpointer 记录状态       ← 【落地第 3 张表: checkpoints / writes】
        ├─ 逐节点跑 LangGraph（模型调用、工具调用）
        ├─ 每产生一个事件 → 写 event_store ← 【落地第 4 张表: run_events】
        └─ 结束后更新 run 状态 (success/error) ← 【更新 runs 表】
   ▼
[流出]  sse_consumer()                 ← 把事件流式推回浏览器
   └─ 前端逐条渲染模型回复、工具调用、思考过程
```

关键词：**runs、threads_meta、checkpoints、run_events** 就是那 4 个最终落库的表。

---

## 3. 每一步详细拆解（含文件 + 函数）

### 步骤 A：路由入口
**文件**：`backend/app/gateway/routers/thread_runs.py`
**函数**：`stream_run()`
- 它读到你 POST 的 body，调用 `start_run()` 创建运行，然后返回一个 `StreamingResponse`（SSE 流）。
- 你看到的字是一个个事件推送回来的（`event: data` 格式）。

> body 长什么样 → `backend/app/gateway/run_models.py` 的 `RunCreateRequest`
> 关键字段：`input.messages`（你的话）、`assistant_id`、`context.model_name`（用哪个模型）、`multitask_strategy`。

### 步骤 B：业务编排
**文件**：`backend/app/gateway/services.py`
**函数**：`start_run()` ← **这条链路的心脏**
它做了：
1. `validate_thread_id()` 校验线程 id
2. `get_app_config().get_model_config(model_name)` 校验模型在允许列表
3. `thread_store.check_access()` 校验你有权用这个线程
4. `build_run_config()` 组装运行配置（含 `recursion_limit`、`thread_id`、可选 `agent_name`）
5. `normalize_input()` 把你发的 `{"messages":[...]}` 转成 LangChain 消息对象
6. `inject_authenticated_user_context()` 把当前用户 ID 塞进运行上下文
7. **`run_mgr.create_or_reject()`** ← 创建 run 记录，**开始落库**
8. **`run_agent()`** ← 启动后台任务执行 agent

### 步骤 C：落库 + 执行 agent
**文件**：`backend/packages/harness/deerflow/runtime/runs/worker.py`
**函数**：`run_agent()`，以及它内部的 `RunManager` / `RunJournal` / event store

- `create_or_reject()`：在 `runs` 表插入一条记录（status=pending，含 run_id、thread_id、model_name、assistant_id）
- `_ensure_thread_metadata()`：确保 `threads_meta` 表有这条 thread 的元数据（标题、所属用户）
- 执行过程中：
  - **checkpointer** 记录每一步的图状态 → `checkpoints` / `writes` 表（这就是"重启后还能接着聊"的原因）
  - **event_store / RunJournal** 把每个事件（AI 消息、工具调用、token 用量）写入 `run_events` 表
- 结束后把 `runs` 表该记录的 status 更新为 `success` / `error`，并记录 token 数

### 步骤 D：流式回传
**文件**：`backend/app/gateway/services.py`
**函数**：`sse_consumer()`
- 从 stream bridge 订阅 run 的事件，逐条转成 SSE 帧 `yield` 给浏览器。
- 你前端看到的"字往外蹦"，就是这里一行行推的。

---

## 4. 最终落到数据库的 4 张表（对应你 Navicat 看到的）

| 表 | 写入时机 | 内容 |
|----|---------|------|
| `runs` | `start_run` 时插入，结束时更新 | 一次运行的元数据：run_id、thread_id、status、model_name、token 数 |
| `threads_meta` | 首次运行/自动创建 | 线程的元数据：标题、所属 user_id、assistant_id |
| `checkpoints` + `writes` | agent 每走一步 | LangGraph 的图状态快照（对话消息本体在这里，是"上下文"的存储） |
| `run_events` | 执行中每个事件 | 事件流：AI 消息原文、工具调用轨迹、token 明细 |

> 注意：**对话消息的"本体"存在 `checkpoints`**（LangGraph 状态），`run_events` 是便于展示/审计的事件流水。
> 所以你在 Navicat 看 `checkpoints` 里是对话的完整状态，`run_events` 里是按时间排序的事件。

---

## 5. 更简单的验证方法（不用读源码）

对照上面链路，你可以直接看**真实的落库结果**来验证理解：

```sql
-- 你刚发的那句话，在 runs 表里能看到
SELECT run_id, thread_id, status, model_name, created_at FROM runs ORDER BY created_at DESC LIMIT 5;

-- 线程元数据
SELECT thread_id, title, user_id FROM threads_meta ORDER BY created_at DESC LIMIT 5;

-- 事件流水（AI 回复原文）
SELECT event_type, seq, run_id FROM run_events WHERE thread_id='你的thread_id' ORDER BY seq DESC LIMIT 10;
```

> 比读代码直观得多：**发一句话 → 查这几张表 → 立刻看到链路每一环确实落了库**。

---

## 6. 如果你想深入某一步

| 你想看 | 去这个文件 |
|--------|-----------|
| agent 怎么构建（lead_agent 图） | `backend/packages/harness/deerflow/agents/lead_agent/agent.py` |
| 模型怎么被调用（DeepSeek/Ollama） | `backend/packages/harness/deerflow/models/factory.py` |
| 子 agent 委派 | `backend/packages/harness/deerflow/subagents/executor.py` |
| 沙箱（agent 执行命令） | `backend/packages/harness/deerflow/sandbox/` |
| 记忆（deermem） | `backend/packages/harness/deerflow/agents/memory/` |
| 内置工具 | `backend/packages/harness/deerflow/tools/builtins/` |

> **建议顺序**：先看懂上面的链路地图 + 用第 5 节 SQL 验证一遍落库，再按需深入某一环。
> 不要一开始就硬啃 agent.py 的英文注释——那是给最底层 agent 图看的，脱离链路很难懂。
