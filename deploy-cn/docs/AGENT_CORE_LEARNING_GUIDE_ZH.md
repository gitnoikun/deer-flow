# DeerFlow Agent 核心学习路线

> 面向已经能够部署服务、启动本地后端并使用断点调试的开发者。
> 本路线只聚焦 Agent 的通用原理和 DeerFlow 中对应的生产实现，主动降低前端样式、普通 CRUD、部署编排和渠道接入等内容的优先级。

## 1. 学习目标

完成这条路线后，应当能够独立解释并调试下面这条链路：

```text
用户请求
  -> Gateway 创建 Run
  -> 组装 Agent：模型 + Prompt + Tools + Middleware + State
  -> LangGraph 执行
  -> 模型返回文本或 tool_calls
  -> 执行工具并生成 ToolMessage
  -> 将新状态再次交给模型
  -> 写入 checkpoint 并发送流式事件
  -> 完成、失败、取消或超时
```

最终检验标准不是“看完了多少源码”，而是能够回答：

1. 谁决定下一步调用哪个工具？
2. 工具定义以什么形式进入模型请求？
3. 工具结果如何与原始调用对应？
4. 哪些状态会跨模型调用、跨 Run、跨进程保存？
5. Agent 根据什么条件继续循环或结束？
6. 模型异常、工具异常、超时和取消分别如何收尾？
7. 上下文过长后，哪些内容被保留、摘要或丢弃？
8. 子 Agent 如何隔离执行，又如何把结果交回 Lead Agent？

## 2. 推荐学习方法

采用“纵向切片 + 断点实验”，不要按目录从头通读。

每次实验只追踪一条请求，并记录六类数据：

```text
1. 输入：HTTP Body、HumanMessage、RunnableConfig
2. 组装：模型、System Prompt、Tools、Middleware
3. 模型请求：实际发送给模型的 messages/input 和 tools
4. 模型响应：文本、tool_calls、finish_reason、usage
5. 状态变化：本轮新增或修改了哪些 State 字段
6. 外部结果：SSE 事件、Run 状态、checkpoint
```

建议为每个实验保留一页学习记录，格式如下：

```markdown
## 实验名称

- 输入：
- 预期行为：
- 实际调用链：
- 模型看到的内容：
- State 前后变化：
- 关键断点：
- 与预期不一致的地方：
- 我的结论：
```

不要在第一次调试时进入每一个框架内部函数。遇到 LangChain 或 LangGraph 内部调用时，先把它当成黑盒，只观察输入、输出和状态变化；当黑盒行为无法解释时再进入源码。

---

## 阶段 0：大模型 API 与模型特性基础

建议用 2～3 天完成。目标不是熟悉某一家厂商的所有参数，而是掌握 Agent 依赖的通用模型协议。

### 0.1 理解两类常见 API 形态

目前工程中常见的模型接口大致分为两类：

- Chat Completions 风格：核心输入是 `messages`，兼容实现很多。
- Responses/统一响应风格：把文本、图片、工具调用等统一为输入和输出项目，通常更适合新的多模态和 Agent 能力。

不同提供商字段可能不同，但 Agent 真正依赖的公共概念基本一致：

- 模型标识
- System、User、Assistant、Tool 等消息角色
- 普通文本输出
- 流式输出
- 工具定义和工具调用
- 结构化输出
- token usage
- finish/stop reason
- 超时、限流和服务端错误

先使用当前 `config.yaml` 已配置成功的模型做实验，不需要为了学习同时接入很多厂商。

### 0.2 消息与角色

必须理解下面几种消息的语义：

- `SystemMessage`：框架拥有的规则、身份、权限边界。
- `HumanMessage`：用户输入以及其他不可信数据。
- `AIMessage`：模型输出；可能包含文本，也可能包含 `tool_calls`。
- `ToolMessage`：工具执行结果，必须与某个 `tool_call_id` 对应。

关键认识：消息角色不仅影响对话格式，也代表信任边界。用户文本、网页内容、文件内容和子任务描述不能因为经过字符串清洗，就自动升级为系统指令。

实验：

1. 发送只有一条用户消息的请求。
2. 增加一条 System 指令，观察优先级变化。
3. 连续对话两轮，观察历史消息如何被重新发送。
4. 在用户输入中伪造“system”文字，确认它仍然只是用户内容。

### 0.3 非流式与流式输出

非流式调用通常一次返回完整结果；流式调用会持续返回增量事件。

需要区分：

- 文本增量不等于完整消息。
- 工具参数也可能分多个增量片段到达。
- 流结束不一定代表业务成功，仍要检查错误、finish reason 和 Run 状态。
- 客户端断开连接不一定意味着后端 Agent 已停止。
- SSE 是传输方式，Agent State 才是执行事实。

实验：用同一个问题分别执行非流式和流式调用，记录首 token 时间、完整耗时、事件数量和最终拼接结果。

### 0.4 工具调用协议

工具调用是学习 Agent 最重要的 API 部分。

模型接收到的工具一般包括：

```json
{
  "name": "read_file",
  "description": "Read a file from the workspace",
  "parameters": {
    "type": "object",
    "properties": {
      "path": { "type": "string" }
    },
    "required": ["path"]
  }
}
```

模型不会真正执行函数，它只生成类似下面的调用意图：

```json
{
  "id": "call_123",
  "name": "read_file",
  "args": { "path": "README.md" }
}
```

宿主程序负责：

1. 校验工具名称和参数。
2. 检查权限。
3. 执行函数。
4. 处理超时和异常。
5. 生成带有相同 `tool_call_id` 的 ToolMessage。
6. 再次调用模型，让模型根据结果决定下一步。

必须牢记：**模型负责提出动作，运行时负责授权并执行动作。**

实验：

1. 只提供一个无副作用的工具。
2. 提问一个必须调用该工具才能回答的问题。
3. 打印 AIMessage 中的 `tool_calls`。
4. 故意返回工具错误，观察模型是否重试或解释失败。
5. 故意给出非法参数，观察 Schema 校验发生在哪一层。

### 0.5 结构化输出

结构化输出与工具调用相似，但目的不同：

- 工具调用用于请求宿主执行动作。
- 结构化输出用于约束模型最终答案的数据形状。

学习重点：

- JSON Schema 约束
- 必填字段与枚举
- 拒答或截断时可能没有合法结构
- 不能只依赖“请输出 JSON”这类自然语言约束
- 解析失败后的重试应当有次数上限

实验：让模型输出一个包含 `summary`、`risk_level`、`actions` 的固定结构，并测试缺失字段、错误枚举和输出截断。

### 0.6 常见模型特性

选择模型时不要只比较“聪明程度”，还应观察：

- 指令遵循：是否稳定遵循 System 规则和输出格式。
- 工具调用准确性：名称、参数和调用时机是否可靠。
- 推理能力：复杂任务规划能力，以及是否支持 reasoning/thinking 配置。
- 上下文窗口：能接收多少输入，不代表应该无限塞入历史。
- 最大输出：输出上限与上下文窗口不是同一个概念。
- 多模态：是否支持图片、音频或文件输入。
- 延迟：首 token 延迟和完整响应耗时。
- 成本：输入、输出、缓存和推理 token 的计费可能不同。
- 可重复性：即使 temperature 较低，也不能假设输出绝对确定。
- 工具并行：模型可能在一个 AIMessage 中请求多个工具。

DeerFlow 中的模型创建入口：

- `backend/packages/harness/deerflow/models/factory.py::create_chat_model`
- `backend/packages/harness/deerflow/models/patched_openai.py`

第一遍只读 `factory.py`，先不要深入每个供应商兼容补丁。

#### 在 DeerFlow 中的真实调用走向

以 OpenAI-compatible 模型的流式请求为例：

```text
_assemble_lead_agent
  -> create_chat_model
  -> create_agent 将模型绑定到 Agent 图
  -> Middleware.awrap_model_call
  -> PatchedChatOpenAI._astream
  -> 模型服务 HTTP API
  -> AIMessageChunk 增量返回
  -> LangGraph 合并为 AIMessage 并写回 State
```

#### 建议断点

按顺序进入：

1. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::_assemble_lead_agent`，观察最终模型名称和运行参数。
2. `backend/packages/harness/deerflow/models/factory.py::create_chat_model`，当前约第 174 行，观察模型类、API 地址、超时、重试和模型参数。
3. `backend/packages/harness/deerflow/agents/middlewares/input_sanitization_middleware.py::awrap_model_call`，当前约第 452 行，观察发给模型前的消息。
4. OpenAI-compatible 模型进入 `backend/packages/harness/deerflow/models/patched_openai.py::_get_request_payload`，当前约第 62 行，观察最终请求载荷。
5. 非流式调用进入 `_agenerate`，当前约第 94 行；流式调用进入 `_astream`，当前约第 101 行。
6. 在 `_astream` 返回处观察原始增量如何逐步形成文本、tool call 和 usage。

如果当前配置使用的不是 OpenAI-compatible 模型，第 4～6 步会进入对应模型类；前 3 步仍然适用。此阶段不要追 HTTP 客户端的每一层封装，看到最终请求和原始响应即可。

### 0.7 常见失败与重试原则

需要能区分：

- 认证或权限错误：通常不应自动重试。
- 参数和上下文错误：修改请求后才能重试。
- 限流：读取服务端提示，使用退避和抖动。
- 临时服务端错误：可进行有上限的重试。
- 连接失败或超时：结果可能未知，涉及副作用时不能盲目重放。
- 内容过滤或拒答：不应伪装成普通成功回答。
- 输出截断：检查 finish reason，不要只看已有文本。

Agent 的重试比普通聊天复杂，因为一次重试可能重复执行有副作用的工具。生产工具需要考虑幂等键、去重、操作回执和“结果未知”状态。

### 0.8 阶段 0 完成标准

在不看框架源码的情况下，能够手写或清楚描述下面这个最小循环：

```python
messages = [user_message]

while True:
    response = call_model(messages, tools=tools)
    messages.append(response)

    if not response.tool_calls:
        return response.text

    for call in response.tool_calls:
        result = validate_and_execute(call)
        messages.append(tool_message(call.id, result))
```

这个循环不是生产实现，但它是理解 LangGraph Agent 的基准模型。

---

## 阶段 1：跟踪一次纯模型 Run

建议用 1 天完成。

### 目标

理解 HTTP 请求如何变成一次可追踪、可取消、可持久化的 Agent Run。

### 实验输入

```text
只回复 OK，不要调用任何工具。
```

### 建议断点

按顺序进入：

1. `backend/app/gateway/routers/thread_runs.py::stream_run`，当前约第 860 行。
2. `backend/app/gateway/services.py::start_run`，当前约第 1197 行。
3. `backend/packages/harness/deerflow/runtime/runs/worker.py::run_agent`，当前约第 561 行。
4. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::assemble_lead_agent`，当前约第 754 行。
5. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::_assemble_lead_agent`，当前约第 869 行。
6. `backend/packages/harness/deerflow/runtime/runs/worker.py` 中的 `agent.astream(...)`，当前约第 989 行。

### 真正执行走向

```text
stream_run
  -> start_run
  -> RunManager 创建并登记 RunRecord
  -> 后台任务调用 run_agent
  -> assemble_lead_agent / _assemble_lead_agent
  -> create_agent 生成已编译的 Agent 图
  -> worker 给图挂载 checkpointer 和 store
  -> agent.astream
  -> 模型节点
  -> SSE/RunEvent/Checkpoint
  -> RunManager 写入最终状态
```

这条链里，Router 负责 HTTP 协议，Service 负责组织一次启动，RunManager 负责 Run 生命周期，Worker 负责真正执行，Agent factory 负责组装图。第一次学习时应把这几个职责明确分开。

优先使用函数断点，因为行号会随代码变化。

### 观察内容

- `thread_id` 和 `run_id` 的来源与区别
- `input_payload`
- `RunnableConfig.configurable`
- 最终解析出的模型名称
- 完整 System Prompt
- 最终工具列表
- Middleware 顺序
- `astream()` 输出的 chunk
- Run 完成前后的状态变化

### 完成标准

能够画出从 HTTP 请求到第一次模型调用，再到 SSE 结束事件的调用链，并说明 RunManager、Worker 和 Graph 各自负责什么。

---

## 阶段 2：跟踪完整工具调用循环

建议用 2 天完成。

### 目标

理解 ReAct/工具调用循环，而不是只看到最终回答。

### 实验输入

选择一个明确需要读取工作区文件的问题，例如：

```text
读取 README.md，告诉我项目使用什么后端框架。必须先读取文件再回答。
```

### 重点源码

- `backend/packages/harness/deerflow/tools/tools.py::get_available_tools`
- `backend/packages/harness/deerflow/agents/lead_agent/agent.py::build_middlewares`
- `backend/packages/harness/deerflow/agents/lead_agent/agent.py::_assemble_lead_agent`
- `backend/packages/harness/deerflow/runtime/runs/worker.py::run_agent`

### 真正执行走向

以 `read_file` 为例：

```text
get_available_tools
  -> create_agent 将工具 Schema 绑定给模型
  -> 模型返回 AIMessage(tool_calls=[read_file])
  -> LangChain/LangGraph 的 ToolNode 识别调用
  -> Tool Middleware 链执行权限、错误和结果处理
  -> sandbox/tools.py::read_file_tool
  -> 生成相同 tool_call_id 的 ToolMessage
  -> ToolMessage 写入 State.messages
  -> 图重新进入模型节点
  -> 模型根据工具结果生成最终 AIMessage
```

`ToolNode` 的通用分发逻辑来自 LangChain/LangGraph，不在 DeerFlow 仓库中。第一遍无需进入框架源码；从 AIMessage 跳到 Tool Middleware，再进入具体工具即可。

### 建议断点

按顺序进入：

1. `backend/packages/harness/deerflow/tools/tools.py::get_available_tools`，当前约第 59 行，确认工具为什么会被加入。
2. `backend/packages/harness/deerflow/agents/lead_agent/agent.py` 最终的 `create_agent(...)`，当前约第 1175 行，检查 `final_tools`。
3. `backend/packages/harness/deerflow/models/patched_openai.py::_astream`，当前约第 101 行，捕获模型返回的 tool call 增量。
4. `backend/packages/harness/deerflow/agents/middlewares/tool_error_handling_middleware.py::awrap_tool_call`，当前约第 142 行，观察工具请求和异常边界。
5. `backend/packages/harness/deerflow/sandbox/tools.py::read_file_tool`，当前约第 2203 行；异步路径继续进入 `_read_file_tool_async`，当前约第 2267 行。
6. 回到 `backend/packages/harness/deerflow/runtime/runs/worker.py` 的 `agent.astream(...)` 循环，检查包含 ToolMessage 的 `values` chunk。
7. 再次进入模型的 `_astream`，确认第二次请求已经包含 AIMessage tool call 和对应 ToolMessage。

若使用其他工具，只替换第 5 步的具体工具函数，前后链路不变。

### 必须捕获的对象

1. 第一次模型请求中的工具 Schema。
2. 第一次 AIMessage 的 `tool_calls`。
3. 工具实际收到的参数。
4. 工具执行结果或异常。
5. 生成的 ToolMessage 及其 `tool_call_id`。
6. 第二次模型请求的消息列表。
7. 最终 AIMessage。

### 故障实验

- 请求读取不存在的文件。
- 请求一个权限范围外的路径。
- 让工具返回很大的结果。
- 在安全的测试工具中制造超时。
- 如果模型一次请求多个工具，观察它们如何进入同一轮状态。

### 完成标准

能够仅根据消息序列判断 Agent 当前处于“等待工具”“获得工具结果”还是“已完成回答”的状态。

---

## 阶段 3：State、Reducer 与 Checkpoint

建议用 2 天完成。

### 目标

理解生产 Agent 为什么不仅是一个 `while` 循环。

### 重点源码

- `backend/packages/harness/deerflow/agents/thread_state.py::ThreadState`
- `backend/packages/harness/deerflow/runtime/runs/manager.py::RunManager`
- `backend/packages/harness/deerflow/runtime/checkpoint_state.py`
- `backend/packages/harness/deerflow/runtime/runs/worker.py`

### 真正执行走向

```text
run_agent
  -> 确认 checkpoint mode 与 thread_id
  -> 创建 CheckpointStateAccessor
  -> 读取并物化运行前 State
  -> 捕获 rollback point
  -> 将 checkpointer 挂到 Agent 图
  -> agent.astream 推进图
  -> LangGraph 在每个 super-step 自动写 checkpoint
  -> Gateway 读取状态时通过 CheckpointStateAccessor.aget
  -> 取消或失败时按策略恢复运行前状态
```

正常图执行中的大部分 checkpoint 写入由 LangGraph 自动完成，因此不会全部表现为 DeerFlow 显式调用 `put()`。不要因为在业务代码里没看到手写数据库操作，就认为状态没有持久化。

### 建议断点

按顺序进入：

1. `backend/packages/harness/deerflow/runtime/runs/worker.py::run_agent`，当前约第 561 行。
2. 同文件约第 755 行，观察 checkpoint mode 如何注入 config。
3. 同文件约第 908～910 行，观察线程级 checkpoint 锁和运行前 rollback point。
4. 同文件约第 951～953 行，观察 checkpointer 和 store 如何挂载到图。
5. 同文件约第 985～1000 行，逐个观察 `agent.astream(...)` 的 super-step 输出。
6. `backend/packages/harness/deerflow/runtime/checkpoint_state.py::CheckpointStateAccessor.aget`，当前约第 148 行，观察持久数据如何被物化成 State。
7. 手动更新、回滚或压缩状态时，进入 `CheckpointStateAccessor.aupdate`，当前约第 196 行。
8. 取消实验时回到 `worker.py` 约第 1158 行附近，观察是否以及如何恢复 checkpoint。

先以默认 `full` mode 学习。理解完整状态快照后，再研究 `delta` mode 的消息增量、线性恢复和兼容性约束。

### 核心概念

- Thread：长期会话和状态容器。
- Run：Thread 上的一次执行。
- State：图在当前时刻的业务数据。
- Reducer：多个状态写入如何合并。
- Checkpoint：可恢复的图状态快照及其执行位置。
- Run event：面向流式展示、调试和审计的事件，不等同于 State。

### 实验

1. 连续对话两轮，比较两次模型请求的消息。
2. 在工具执行后中断 Run，查看已有 checkpoint。
3. 重启本地后端，重新读取同一个 Thread。
4. 取消一次 Run，比较是否回滚前后的 State。
5. 分别观察普通字段、消息字段和带自定义 Reducer 字段的更新方式。

### 完成标准

能够解释：为什么聊天记录、流事件、Run 状态和 checkpoint 是四种不同的数据；以及为什么不能直接手写数据库记录来替代图的 checkpoint API。

---

## 阶段 4：Middleware 与上下文工程

建议用 2～3 天完成。

### 目标

理解模型每次真正看到的上下文是如何被动态构造和约束的。

### 推荐阅读顺序

1. `input_sanitization_middleware.py`
2. `dynamic_context_middleware.py`
3. `tool_error_handling_middleware.py`
4. `summarization_middleware.py`
5. `loop_detection_middleware.py`
6. `token_budget_middleware.py`
7. `terminal_response_middleware.py`

目录：`backend/packages/harness/deerflow/agents/middlewares/`

### 真正执行走向

Middleware 不是一个独立后台流程，而是被 `create_agent` 包裹到图的模型节点和工具节点周围：

```text
_assemble_lead_agent
  -> build_middlewares 按顺序创建 Middleware 实例
  -> create_agent(middleware=[...])
  -> before_agent
  -> before_model
  -> 多层 awrap_model_call 嵌套
  -> 真实模型调用
  -> after_model
  -> 如果有工具：多层 awrap_tool_call -> 真实工具
  -> 下一轮 before_model / 模型调用
  -> after_agent
```

`wrap_*` 类型通常像洋葱一样嵌套，不能简单理解为列表从上到下执行一次。调试时同时观察“进入 handler 前”和“handler 返回后”。

### 建议断点

第一次只选下面几个代表性断点，不要给所有 Middleware 同时下断点：

1. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::build_middlewares`，当前约第 457 行，记录实际 Middleware 列表和顺序。
2. `dynamic_context_middleware.py::abefore_agent`，Lead Agent 路径当前约第 381 行，比较注入前后的消息。
3. `input_sanitization_middleware.py::awrap_model_call`，当前约第 452 行，观察不可信输入如何只在请求层被处理。
4. `summarization_middleware.py::abefore_model`，当前约第 532 行，用长上下文实验确认何时触发摘要。
5. `loop_detection_middleware.py::aafter_model`，当前约第 670 行，观察检测结果；下一次模型请求进入 `awrap_model_call`，当前约第 719 行，观察警告如何注入。
6. `token_budget_middleware.py::aafter_model`，当前约第 282 行；下一次请求进入 `awrap_model_call`，当前约第 314 行。
7. `terminal_response_middleware.py::aafter_model`，当前约第 196 行；必要时继续进入 `awrap_model_call`，当前约第 208 行。
8. 工具故障实验进入 `tool_error_handling_middleware.py::awrap_tool_call`，当前约第 142 行。

完成一次断点记录后，把每个 Middleware 标注为“修改 State”“只修改本次模型请求”或“转换异常/响应”。这是理解 Middleware 最有效的分类方式。

每读一个 Middleware，都回答：

- 它在模型调用前、调用后，还是工具调用前后运行？
- 它读取哪些 State 和 runtime context？
- 它修改模型请求、模型响应还是持久 State？
- 它失败后会阻止整次 Run 吗？
- 它与前后 Middleware 交换顺序后，语义是否变化？

### 上下文概念辨析

- 原始消息历史：用户和 Agent 的实际交互。
- `summary_text`：历史压缩后投影给模型的上下文。
- Durable Memory：跨会话保留的用户事实或偏好。
- Skill context：当前激活技能的引用和规则。
- RAG：从外部知识源按需检索的内容。

不要把这几类数据全部简单追加到 System Prompt。需要根据来源判断其信任等级、生命周期和 token 成本。

### 实验

- 制造足够长的对话触发摘要，比较摘要前后的 messages 和 `summary_text`。
- 制造重复工具调用，观察 loop detection 如何结束循环。
- 降低 token budget，观察停止原因如何进入最终状态。
- 在一个 Middleware 前后分别打印模型请求，确认它实际做了什么。

### 完成标准

能够解释某次模型调用的最终上下文是由哪些来源组合出来的，并能定位错误上下文是在哪个 Middleware 被加入的。

---

## 阶段 5：子 Agent 委派

建议用 2 天完成。

### 前置条件

只有在工具调用、State 和 Middleware 已经理解后再进入本阶段。

### 重点源码

- `backend/packages/harness/deerflow/subagents/executor.py::SubagentExecutor`，当前约第 541 行。
- `backend/packages/harness/deerflow/subagents/executor.py::_create_agent`，当前约第 682 行。
- `backend/packages/harness/deerflow/subagents/executor.py` 中子 Agent 的 `agent.astream(...)`，当前约第 1246 行。
- `backend/packages/harness/deerflow/tools/builtins/task_tool.py`

### 真正执行走向

```text
Lead Agent 模型返回 task tool_call
  -> LangGraph ToolNode
  -> task_tool
  -> 构造 SubagentExecutor
  -> execute_async 提交到隔离的持久事件循环
  -> _aexecute 获取并发执行许可
  -> _aexecute_admitted 组装子 Agent
  -> _create_agent
  -> 子 Agent agent.astream(stream_mode="values")
  -> 持续更新 SubagentResult 和 task_* 事件
  -> task_tool 轮询到终态
  -> 生成父图可识别的 ToolMessage
  -> Lead Agent 根据子任务结果继续推理
```

从 Lead Agent 视角看，委派仍然是一次工具调用；复杂性主要集中在这个工具背后的隔离执行、并发控制和结果回传。

### 建议断点

按顺序进入：

1. 在 Lead Agent 的模型响应处捕获名称为 `task` 的 tool call，并记录它的 `tool_call_id`。
2. `backend/packages/harness/deerflow/tools/builtins/task_tool.py::task_tool`，当前约第 264 行，观察任务描述、验收条件和父运行上下文。
3. 同文件约第 504 行，观察 `executor.execute_async(...)` 返回的内部执行 ID 与 provider `tool_call_id` 的区别。
4. `backend/packages/harness/deerflow/subagents/executor.py::execute_async`，当前约第 1471 行，观察任务如何被提交到隔离事件循环。
5. `executor.py::_aexecute`，当前约第 1033 行，观察等待并发许可的过程。
6. `executor.py::_aexecute_admitted`，当前约第 1058 行，观察获得许可后的实际执行。
7. `executor.py::_create_agent`，当前约第 682 行，比较子 Agent 与 Lead Agent 的模型、Prompt、Tools、Middleware 和 checkpointer。
8. `executor.py` 中子 Agent 的 `agent.astream(...)`，当前约第 1246 行，观察独立消息循环。
9. 回到 `task_tool` 的结果轮询和 ToolMessage 构造处，确认回传父图的关联 ID、status、stop reason 和最终文本。
10. 再次进入 Lead Agent 模型调用，确认它看到的是 task ToolMessage，而不是子 Agent 的完整内部消息历史。

### 核心问题

- Lead Agent 根据什么决定委派？
- 委派任务在协议层为什么仍然是一次工具调用？
- 子 Agent 收到哪些父上下文，哪些内容不会继承？
- 子 Agent 的工具和技能如何限制？
- 父子 Agent 如何隔离消息和 checkpoint namespace？
- 子 Agent 的中间步骤如何变成 `task_*` 事件？
- 子 Agent 完成、失败、超时和被取消后分别返回什么？
- Lead Agent 如何判断应该采用、补充还是重试子 Agent 结果？

### 实验

让 Lead Agent 委派一个范围明确的文件分析任务，同时记录：

1. Lead Agent 生成的 task tool call。
2. 传给子 Agent 的任务描述和验收条件。
3. 子 Agent 的 System/HumanMessage。
4. 子 Agent 独立的工具调用循环。
5. 子 Agent 最终结果和 stop reason。
6. 回到 Lead Agent 的 ToolMessage。
7. Lead Agent 如何生成最终回答。

### 完成标准

能够说明“多 Agent”并不是多个模型随意聊天，而是受权限、上下文、并发、预算和结果协议约束的任务委派系统。

---

## 阶段 6：生产可靠性与评估

建议在完成主链路后持续学习。

真正生产化的 Agent 需要关注：

- 工具副作用和幂等性
- 权限校验与不可信输入边界
- 超时、取消和未知结果
- 循环、token 与子任务预算
- checkpoint 一致性和恢复
- 流事件丢失与客户端重连
- 可观测性：模型调用、工具调用、状态变化和错误归因
- 回归测试与评估数据集

### 失败链路的真实走向

生产问题建议按“故障发生在哪一层”分别跟踪：

```text
模型失败
  -> LLMErrorHandlingMiddleware.awrap_model_call
  -> 判断是否可重试、退避或熔断
  -> 重试成功，或生成带错误标记的 fallback AIMessage
  -> Worker 根据最终图结果更新 Run 状态

工具失败
  -> ToolErrorHandlingMiddleware.awrap_tool_call
  -> 异常转换成结构化 ToolMessage
  -> 模型决定改参数、换工具或向用户报告失败

取消/执行失败
  -> worker.run_agent 的取消或异常分支
  -> RunManager 原子更新状态
  -> 必要时恢复运行前 checkpoint
  -> 发布终态事件并清理执行资源
```

### 建议断点

1. 模型故障：`backend/packages/harness/deerflow/agents/middlewares/llm_error_handling_middleware.py::awrap_model_call`，当前约第 835 行。
2. 模型重试判断：同文件 `_classify_error`，当前约第 496 行，以及 `_build_retry_delay_ms`，当前约第 591 行。
3. 工具故障：`tool_error_handling_middleware.py::awrap_tool_call`，当前约第 142 行。
4. 用户取消：`backend/packages/harness/deerflow/runtime/runs/worker.py` 的 `except asyncio.CancelledError`，当前约第 1122 行。
5. Run 终态写入：`backend/packages/harness/deerflow/runtime/runs/manager.py::set_status`，当前约第 917 行，以及 `set_status_if_not_cancelled`，当前约第 976 行。
6. 回滚：`worker.py::_rollback_to_pre_run_checkpoint`，用函数断点定位，比较恢复前后 State。
7. 子 Agent 事件持久化：`worker.py::_SubagentEventBuffer.flush` 附近，当前约第 547～553 行，观察批量写入而不是每步单写。

每次只制造一种故障，否则很难判断到底是哪一层改变了最终结果。

推荐做两个小改动来检验理解：

1. 新增一个无副作用的只读工具，包含参数校验、错误处理和单元测试。
2. 新增一个简单 Middleware，例如记录每次 Run 的模型调用次数，并验证它不会破坏 State 和流事件。

评价 Agent 改动时，不要只用“这次回答看起来不错”。至少记录：

- 任务成功率
- 工具选择和参数正确率
- 平均模型调用轮数
- token 使用量
- 延迟
- 超时或循环比例
- 有副作用操作的重复执行比例
- 同一测试集上的回归情况

---

## 3. 两周执行计划

### 第 1 周：单 Agent 主链路

- 第 1 天：阶段 0 的消息、角色、普通响应和流式响应。
- 第 2 天：阶段 0 的工具调用、结构化输出、错误与重试。
- 第 3 天：跟踪一次不调用工具的完整 Run。
- 第 4 天：跟踪一次完整工具调用循环。
- 第 5 天：制造工具错误、非法参数、超时和多工具调用。
- 第 6 天：学习 ThreadState、Reducer 和 checkpoint。
- 第 7 天：整理调用链图和本周仍无法解释的问题。

### 第 2 周：上下文与子 Agent

- 第 8 天：阅读 Agent 组装和 Middleware 顺序。
- 第 9 天：调试 summarization、loop detection 和 token budget。
- 第 10 天：区分消息历史、摘要、长期记忆、Skill 和 RAG。
- 第 11 天：跟踪一次子 Agent 委派。
- 第 12 天：制造子 Agent 失败、超时或达到上限的情况。
- 第 13 天：实现一个只读工具或简单 Middleware，并编写测试。
- 第 14 天：不看笔记，从 HTTP 入口完整讲解一次 Agent Run。

如果每天时间有限，不必追求严格的十四天；保持阶段顺序比完成速度更重要。

## 4. 当前阶段可以低优先级处理的内容

以下内容不是没价值，只是对“理解 Agent 核心”的边际收益较低：

- 前端样式、动画和响应式布局
- 普通页面组件和表单交互
- Slack、Telegram、飞书等渠道适配
- Nginx 与 Docker 编排细节
- 普通用户、文件和配置 CRUD
- 多实例 Scheduler、数据库租约和队列恢复
- 插件安装器与扩展打包
- 各模型供应商的零碎兼容补丁
- MCP 长任务的持久化调度
- 与当前业务无关的复杂 RAG 和向量数据库调优

但下面这些基础不能完全跳过：

- Python `asyncio`
- 异步生成器和 `async for`
- 超时与取消传播
- `ContextVar`
- SSE 基本工作方式
- JSON Schema
- 基础数据库事务和并发一致性

学习深度以“能解释 Agent 运行中的问题”为准，不需要先成为这些领域的专家。

## 5. 源码阅读入口索引

建议按下面顺序建立书签：

1. `backend/app/gateway/routers/thread_runs.py::stream_run`
2. `backend/app/gateway/services.py::start_run`
3. `backend/packages/harness/deerflow/runtime/runs/worker.py::run_agent`
4. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::_assemble_lead_agent`
5. `backend/packages/harness/deerflow/models/factory.py::create_chat_model`
6. `backend/packages/harness/deerflow/tools/tools.py::get_available_tools`
7. `backend/packages/harness/deerflow/agents/lead_agent/agent.py::build_middlewares`
8. `backend/packages/harness/deerflow/agents/thread_state.py::ThreadState`
9. `backend/packages/harness/deerflow/runtime/runs/manager.py::RunManager`
10. `backend/packages/harness/deerflow/subagents/executor.py::SubagentExecutor`

## 6. 最终自测题

完成路线后，尝试在不看源码的情况下回答：

1. 用户发来一条消息后，第一处业务断点应该打在哪里？
2. 模型最终使用哪个名称和配置，是在哪一步决定的？
3. Prompt、Tools、Middleware 和 State Schema 是在哪里组装到一起的？
4. 模型请求调用工具后，为什么 Agent 没有立即结束？
5. ToolMessage 缺少或写错 `tool_call_id` 会发生什么？
6. SSE 已经发送过的文本为什么不一定存在于 checkpoint？
7. 用户断开网页后，后端 Run 是否一定停止？
8. 为什么不能把网页内容直接拼进 System Prompt？
9. 摘要、长期记忆和 RAG 分别解决什么问题？
10. 为什么取消一个有副作用的工具不能简单地理解为“什么都没发生”？
11. 子 Agent 为什么需要独立的上下文和执行上限？
12. 如何判断一次改动提升了 Agent，而不是只对一个示例碰巧有效？

能够结合一次真实断点记录回答这些问题，就已经掌握了 DeerFlow 中最重要、也最能迁移到其他 Agent 项目的核心知识。
