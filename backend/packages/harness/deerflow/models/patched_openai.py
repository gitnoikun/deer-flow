"""Patched ChatOpenAI that preserves thought_signature for Gemini thinking models.

When using Gemini with thinking enabled via an OpenAI-compatible gateway (e.g.
Vertex AI, Google AI Studio, or any proxy), the API requires that the
``thought_signature`` field on tool-call objects is echoed back verbatim in
every subsequent request.

The OpenAI-compatible gateway stores the raw tool-call dicts (including
``thought_signature``) in ``additional_kwargs["tool_calls"]``, but standard
``langchain_openai.ChatOpenAI`` only serialises the standard fields (``id``,
``type``, ``function``) into the outgoing payload, silently dropping the
signature.  That causes an HTTP 400 ``INVALID_ARGUMENT`` error:

    Unable to submit request because function call `<tool>` in the N. content
    block is missing a `thought_signature`.

This module fixes the problem by overriding ``_get_request_payload`` to
re-inject tool-call signatures back into the outgoing payload for any assistant
message that originally carried them.
"""

from __future__ import annotations

import logging
from typing import Any

from langchain_core.language_models import LanguageModelInput
from langchain_core.messages import AIMessage, BaseMessage
from langchain_openai import ChatOpenAI

from deerflow.models.assistant_payload_replay import restore_assistant_payloads

logger = logging.getLogger(__name__)


class PatchedChatOpenAI(ChatOpenAI):
    """ChatOpenAI with ``thought_signature`` preservation for Gemini thinking via OpenAI gateway.

    When using Gemini with thinking enabled via an OpenAI-compatible gateway,
    the API expects ``thought_signature`` to be present on tool-call objects in
    multi-turn conversations.  This patched version restores those signatures
    from ``AIMessage.additional_kwargs["tool_calls"]`` into the serialised
    request payload before it is sent to the API.

    Usage in ``config.yaml``::

        - name: gemini-2.5-pro-thinking
          display_name: Gemini 2.5 Pro (Thinking)
          use: deerflow.models.patched_openai:PatchedChatOpenAI
          model: google/gemini-2.5-pro-preview
          api_key: $GEMINI_API_KEY
          base_url: https://<your-openai-compat-gateway>/v1
          max_tokens: 16384
          supports_thinking: true
          supports_vision: true
          when_thinking_enabled:
            extra_body:
              thinking:
                type: enabled
    """

    def _get_request_payload(
        self,
        input_: LanguageModelInput,
        *,
        stop: list[str] | None = None,
        **kwargs: Any,
    ) -> dict:
        """Get request payload with ``thought_signature`` preserved on tool-call objects.

        Overrides the parent method to re-inject ``thought_signature`` fields
        on tool-call objects that were stored in
        ``additional_kwargs["tool_calls"]`` by LangChain but dropped during
        serialisation.
        """
        # Capture the original LangChain messages *before* conversion so we can
        # access fields that the serialiser might drop.
        original_messages = self._convert_input(input_).to_messages()

        # Obtain the base payload from the parent implementation.
        payload = super()._get_request_payload(input_, stop=stop, **kwargs)

        restore_assistant_payloads(payload.get("messages", []), original_messages, _restore_tool_call_signatures)

        return payload

    def _generate(self, messages: list[BaseMessage], stop: list[str] | None = None, **kwargs: Any) -> Any:
        """Log the outgoing prompt and the returned result for OpenAI-compatible models."""
        _log_llm_request(self, messages)
        result = super()._generate(messages, stop=stop, **kwargs)
        _log_llm_response(result)
        return result

    async def _agenerate(self, messages: list[BaseMessage], stop: list[str] | None = None, **kwargs: Any) -> Any:
        """Log the outgoing prompt and the returned result (async)."""
        _log_llm_request(self, messages)
        result = await super()._agenerate(messages, stop=stop, **kwargs)
        _log_llm_response(result)
        return result

    async def _astream(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: Any = None,
        *,
        stream_usage: bool | None = None,
        **kwargs: Any,
    ) -> Any:
        """Log the outgoing prompt and accumulate the streamed response text."""
        _log_llm_request(self, messages)
        parts: list[str] = []
        async for chunk in super()._astream(
            messages,
            stop=stop,
            run_manager=run_manager,
            stream_usage=stream_usage,
            **kwargs,
        ):
            try:
                text = getattr(chunk, "text", "") or ""
                if text:
                    parts.append(text)
            except Exception:  # pragma: no cover
                pass
            yield chunk
        _log_llm_stream_response(parts)


def _log_llm_request(model: "PatchedChatOpenAI", messages: list[BaseMessage]) -> None:
    """Log the full outgoing model request (all messages, no truncation)."""
    try:
        model_name = getattr(model, "model_name", None) or getattr(model, "model", None) or "?"
        logger.info("[LINK] LLM 请求 -> 模型=%s 消息数=%s", model_name, len(messages))
        for i, msg in enumerate(messages):
            role = getattr(msg, "type", "?")
            content = str(getattr(msg, "content", "") or "")
            logger.info(
                "[LINK][DETAIL]   [%s/%s] role=%s content=%s",
                i + 1,
                len(messages),
                role,
                content,
            )
    except Exception:  # pragma: no cover
        logger.debug("[LINK][DETAIL] 请求日志生成失败", exc_info=True)


def _log_llm_response(result: Any) -> None:
    """Log the full model response (no truncation)."""
    try:
        content = getattr(result, "generations", None)
        if content:
            text = content[0][0].text if content[0] else ""
            kind = "ChatGeneration"
        else:
            text = str(result)
            kind = type(result).__name__
        logger.info("[LINK] LLM 响应 <- %s length=%s", kind, len(text))
        logger.info("[LINK][DETAIL] LLM 响应全文:\n%s", text)
    except Exception:  # pragma: no cover
        logger.debug("[LINK][DETAIL] 响应日志生成失败", exc_info=True)


def _log_llm_stream_response(parts: list[str]) -> None:
    """Log the full accumulated text of a streamed model response (no truncation)."""
    try:
        joined = "".join(parts)
        logger.info("[LINK] LLM 流式响应 <- length=%s", len(joined))
        logger.info("[LINK][DETAIL] LLM 流式响应全文:\n%s", joined)
    except Exception:  # pragma: no cover
        logger.debug("[LINK][DETAIL] 流式响应日志生成失败", exc_info=True)


def _restore_tool_call_signatures(payload_msg: dict, orig_msg: AIMessage) -> None:
    """Re-inject ``thought_signature`` onto tool-call objects in *payload_msg*.

    When the Gemini OpenAI-compatible gateway returns a response with function
    calls, each tool-call object may carry a ``thought_signature``.  LangChain
    stores the raw tool-call dicts in ``additional_kwargs["tool_calls"]`` but
    only serialises the standard fields (``id``, ``type``, ``function``) into
    the outgoing payload, silently dropping the signature.

    This function matches raw tool-call entries (by ``id``, falling back to
    positional order) and copies the signature back onto the serialised
    payload entries.
    """
    raw_tool_calls: list[dict] = orig_msg.additional_kwargs.get("tool_calls") or []
    payload_tool_calls: list[dict] = payload_msg.get("tool_calls") or []

    if not raw_tool_calls or not payload_tool_calls:
        return

    # Build an id → raw_tc lookup for efficient matching.
    raw_by_id: dict[str, dict] = {}
    for raw_tc in raw_tool_calls:
        tc_id = raw_tc.get("id")
        if tc_id:
            raw_by_id[tc_id] = raw_tc

    for idx, payload_tc in enumerate(payload_tool_calls):
        # Try matching by id first, then fall back to positional.
        raw_tc = raw_by_id.get(payload_tc.get("id", ""))
        if raw_tc is None and idx < len(raw_tool_calls):
            raw_tc = raw_tool_calls[idx]

        if raw_tc is None:
            continue

        # The gateway may use either snake_case or camelCase.
        sig = raw_tc.get("thought_signature") or raw_tc.get("thoughtSignature")
        if sig:
            payload_tc["thought_signature"] = sig
