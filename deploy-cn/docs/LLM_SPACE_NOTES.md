# LLM Space 调研笔记

> 结论：**llm-space 不是"监控平台"，是 agent 开发工作台；Linux 官方只发布无 UI 的 server，暂不部署。**
> 记录时间：2026-08-27

## 一、它是什么

`llm-space`（[deer-flow/llm-space](https://github.com/deer-flow/llm-space)）是 DeerFlow 的姊妹项目，
定位是 **Agent 开发者的桌面工作台**：构建 agent、追踪 harness 每一步、回放失败、评估性能。
它**不是**一个部署在服务器上的"监控面板"，而是和 DeerFlow **互补**的开发调试工具。

- 技术栈：Bun monorepo + Electrobun（桌面壳）+ React UI + Pi Agent Core
- 官方定位：DeerFlow 团队内部用它在开发/调试 DeerFlow 之前先验证 agent

## 二、官方发布资产（v4.14.1）

| 资产 | 平台 | 说明 |
| --- | --- | --- |
| `LLMSpace-*-macos-*.dmg` | macOS | 桌面 GUI（含完整 UI） |
| `LLMSpace-performance-*-macos-*.dmg` | macOS | 桌面 GUI 性能版 |
| `llm-space-server-*-linux-{x64,arm64}.tar.gz` | Linux | **无 UI 的 headless 运行时服务端** |

> **注意**：官方**未发布 Windows 安装包**（代码有 `feat(windows)` 支持，但 v4.14.1 release 只有 macOS + Linux server）。

## 三、Linux server 实测（已在服务器验证）

下载并校验（sha256 一致，~36MB），解压后结构：

```
llm-space-server-4.14.1-linux-x64/
├── README.txt
├── bin/llm-space-server      # 预编译二进制（自包含，无需 Bun/Node）
└── server-manifest.json
```

启动方式（`./bin/llm-space-server --help`）：

```
Usage: llm-space-server (--token <token> | --token-stdin) [options]
Options:
  --host <host>   Host to bind. Defaults to 127.0.0.1.
  --port <port>   Port to bind. Defaults to 39123.
  --token <token> Bearer token required by every endpoint.
  --home <path>   Server home. Defaults to ~/.llm-space-server.
```

HTTP 端点探测结果：

- `GET /health` → **200**（健康检查）
- `GET /` 无 token → **401**（需 Bearer token）
- `GET /` 有 token → **404**，`{"error":"Endpoint not found: GET /"}`
- `/api`、`/docs`、`/debug` 均 404

**结论**：它是**纯 HTTP API 的 headless agent 运行时**，**不携带 Web UI 前端页面**。

## 四、为什么暂不部署

1. `llm-space-server` 本质是 **Electrobun 桌面应用的运行时服务端**，需要配套的
   **桌面/Web UI 客户端**才能真正用起来。
2. 官方**目前只发布** macOS 桌面版 + Linux server（无 UI），**没有 Windows / Linux 桌面版安装包**。
3. 部署环境：Windows 本机（无官方包）+ 无桌面的 Linux 服务器（server 无 UI）——
   **两边都缺少能连它的完整 UI 客户端**，存在"有 runtime 无 UI"的缺口。

## 五、以后要部署时的路径

- 优先等官方发布 **Windows/Linux 桌面版**，直接下载安装即可（最省事）。
- 或者在本机装 **Bun** 后**源码自建**桌面版（`bun install` → `mise run build:stable`），
  再让它连服务器上的 `llm-space-server`（`--host 0.0.0.0 --token xxx --port 39123`）。
- 学习 DeerFlow 本身不依赖 llm-space，DeerFlow 已可正常使用。

## 六、当前状态

- 服务器上 `/opt/llm-space`、`/opt/llm-space-download` 等探测文件**已清理**。
- DeerFlow 服务正常（nginx `:2026` → HTTP 200）。
- 本次仅做了只读探测，**未影响任何现有服务**。
