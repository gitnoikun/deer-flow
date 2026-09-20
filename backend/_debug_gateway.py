"""本地 Debug 启动入口 —— 在 PyCharm 里用 `.venv` 解释器 Debug 运行。

作用：
  1. 加载仓库根 `.env`（里面有 DEEPSEEK_API_KEY 等）
  2. 用 uvicorn 启动 app.gateway.app:app，监听 0.0.0.0:8001
  3. 让服务器 nginx（反代到 192.168.77.10:8001）能访问到本地，从而在 PyCharm 打断点

用法（PyCharm）：
  - 右上角运行配置选「Python」，脚本选本文件，解释器选 backend/.venv
  - 点 Debug（虫子图标）启动

说明：不用 uvicorn.run()，而是手动构建 uvicorn.Server + asyncio.run。
  PyCharm 的 pydevd debugger 会给 asyncio 打补丁，导致 uvicorn.run() 内部
  的 asyncio_run(loop_factory=...) 报 parameter 冲突；手动 asyncio.run 可规避。
"""
import os
import sys
from pathlib import Path

import dotenv

# 项目根：本文件在 backend/ 下，上一层是仓库根（config.yaml / .env 在那里）
REPO_ROOT = Path(__file__).resolve().parent.parent
DOTENV = REPO_ROOT / ".env"
if DOTENV.exists():
    dotenv.load_dotenv(DOTENV)

# 显式指定运行时目录，避免落到别处
os.environ.setdefault("DEER_FLOW_HOME", str(Path(__file__).resolve().parent / ".deer-flow"))
os.environ.setdefault("PYTHONPATH", str(Path(__file__).resolve().parent))

# 与服务器 gateway 共用同一份 JWT 签密（从 .deer-flow/.jwt_secret 读取），
# 保证本地签发/验证的 access_token 与服务器 SSR 侧完全一致。
_secret_file = Path(__file__).resolve().parent / ".deer-flow" / ".jwt_secret"
if _secret_file.exists():
    os.environ.setdefault("AUTH_JWT_SECRET", _secret_file.read_text(encoding="utf-8").strip())

import asyncio  # noqa: E402
import logging  # noqa: E402

import uvicorn  # noqa: E402

from app.gateway.app import app  # noqa: E402


class _DropDetailFilter(logging.Filter):
    """控制台 handler 专用：丢弃详尽内容日志（含 [LINK][DETAIL]），避免刷屏。

    这些完整日志（LLM 请求全文/响应全文/接口入参全文）仍然会写入文件 handler，
    因为文件 handler 不加这个 filter。
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            return "[LINK][DETAIL]" not in record.getMessage()
        except Exception:  # pragma: no cover
            return True


def _setup_file_logging() -> Path:
    """把 root logger 的日志改为「控制台(stdout) + 文件」双输出。

    - 控制台走 stdout：PyCharm/PowerShell 不会把 stdout 标红，INFO/WARNING 显示为正常色。
      （Python logging 默认走 stderr，而终端会把整个 stderr 渲染成红色，看着像报错。）
    - 文件用 RotatingFileHandler（10MB × 3 个）收集到 DEER_FLOW_HOME/debug_gateway.log。
    - 挂到 root logger，所有 deerflow.* / app.gateway.* / uvicorn / httpx 日志都进来。
    """
    import logging.handlers  # noqa: PLC0415

    root = logging.getLogger()

    # ① 把 root 上已有的 StreamHandler 指向 stderr 的，改指向 stdout（避免标红）
    for h in root.handlers:
        if isinstance(h, logging.StreamHandler) and h.stream is sys.stderr:
            h.stream = sys.stdout

    # ② 控制台 handler -> stdout（INFO 及以上，控制台不标红）
    #    filter: 丢弃 [LINK][DETAIL] 长日志（完整内容只写文件，控制台不刷屏）
    has_stdout = any(
        isinstance(h, logging.StreamHandler) and h.stream is sys.stdout
        for h in root.handlers
    )
    if not has_stdout:
        console = logging.StreamHandler(sys.stdout)
        console.setLevel(logging.INFO)
        console.setFormatter(logging.Formatter(
            "%(asctime)s - %(levelname)-7s - %(name)s - %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        ))
        console.addFilter(_DropDetailFilter())
        root.addHandler(console)
    else:
        # 已在用某个 stdout handler，给它也挂上 filter 避免刷屏
        for h in root.handlers:
            if isinstance(h, logging.StreamHandler) and h.stream is sys.stdout:
                h.addFilter(_DropDetailFilter())

    # ③ 文件 handler -> DEER_FLOW_HOME/debug_gateway.log（替换旧的文件 handler 避免重复）
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.handlers.RotatingFileHandler)]
    log_dir = Path(os.environ.get("DEER_FLOW_HOME", Path(__file__).resolve().parent / ".deer-flow"))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "debug_gateway.log"

    fh = logging.handlers.RotatingFileHandler(
        log_file,
        maxBytes=10 * 1024 * 1024,  # 10MB
        backupCount=3,
        encoding="utf-8",
    )
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter(
        "%(asctime)s - %(levelname)-7s - %(name)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    ))
    root.addHandler(fh)
    print(f"[debug] 日志将同时写入文件: {log_file}")
    return log_file


def main() -> None:
    # 先在 root 上挂文件 handler（只会加 handler，不会移除既有），
    # 让所有 deerflow.* / app.gateway.* 日志同时进文件。
    _setup_file_logging()

    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=8001,
        # 不启用 reload/loop_factory，避免与 pydevd 的 asyncio 补丁冲突。
        # reload=True 需要额外的子进程机制，debugger 下反而更难控制断点。
        reload=False,
        access_log=True,
        log_level="info",
    )
    server = uvicorn.Server(config)
    asyncio.run(server.serve())


if __name__ == "__main__":
    main()
