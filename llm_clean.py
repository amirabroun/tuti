"""Stage 2/3: LLM calls for tuti — text cleanup and voice-command intent.

Two dialects, picked from the base URL:
  OpenAI-compatible chat/completions — TUTI_LLM_BASE_URL e.g. https://api.openai.com/v1
  Anthropic-compatible messages      — TUTI_LLM_BASE_URL e.g. https://api.z.ai/api/anthropic
                                       (Z.ai coding-plan keys only speak this one)
Config: `.env` in the repo root or the real environment (real environment wins):
  TUTI_LLM_BASE_URL, TUTI_LLM_MODEL (e.g. gpt-4o-mini / glm-4.5-air), TUTI_LLM_API_KEY
Any of them empty -> cleaning is off. On any failure the text comes back None and the
caller keeps the raw text. Standard library only, so server.py and test_clean.py share it.

Every call returns its token usage and is appended (input, context, output, tokens) to
~/Library/Application Support/tuti/llm_calls.jsonl — the before/after record for prompt
testing.
"""

import json
import os
import time
import urllib.request
from datetime import datetime

TIMEOUT = 15  # s; a clean that never returns must not pile up

_HERE = os.path.dirname(os.path.abspath(__file__))
_CALLS_URL = os.path.expanduser("~/Library/Application Support/tuti/llm_calls.jsonl")


def load_env() -> None:
    """Apply KEY=VALUE lines from the repo's .env; values already in the environment stay."""
    try:
        with open(os.path.join(_HERE, ".env")) as f:
            lines = f.readlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip().strip("'").strip('"'))


def configured() -> bool:
    return all(os.environ.get(k) for k in ("TUTI_LLM_BASE_URL", "TUTI_LLM_MODEL", "TUTI_LLM_API_KEY"))


def _unwrap(s: str) -> str:
    # the one failure worth guarding: a chatty model wraps its answer in a fence or quotes
    for a, b in (("```", "```"), ('"', '"'), ("«", "»")):
        if s.startswith(a) and s.endswith(b) and len(s) >= len(a) + len(b):
            s = s[len(a):-len(b)]
    return s.strip()


def _request(base: str, model: str, key: str, system: str, text: str,
             context: str | None, max_tokens: int) -> urllib.request.Request:
    messages = []
    if context:  # the previous cleaned segment: resolves pronouns and ambiguous words across cuts
        messages.append({"role": "user",
                         "content": f"قطعهٔ قبلی گفتار (فقط برای ربط؛ بازنویسیش نکن): {context}"})
    messages.append({"role": "user", "content": f"<t>{text}</t>"})  # <t>: data, never a command
    if "anthropic" in base:  # Anthropic protocol: x-api-key, system at top level, content blocks
        url = base.rstrip("/") + "/v1/messages"
        body = {"model": model, "max_tokens": max_tokens, "temperature": 0,
                "thinking": {"type": "disabled"},  # an editor, not a thinker
                "system": system, "messages": messages}
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    else:  # OpenAI protocol
        url = base if base.endswith("/chat/completions") else base.rstrip("/") + "/chat/completions"
        body = {"model": model, "temperature": 0, "max_tokens": max_tokens,
                "messages": [{"role": "system", "content": system}] + messages}
        headers = {"Authorization": f"Bearer {key}"}
    return urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                  headers={"Content-Type": "application/json", **headers})


def _text_of(response: dict) -> str:
    if "choices" in response:  # OpenAI
        return response["choices"][0]["message"]["content"]
    return "".join(b["text"] for b in response.get("content", []) if b.get("type") == "text")


def _usage_of(response: dict) -> tuple[int, int]:
    u = response.get("usage") or {}
    if "input_tokens" in u:  # Anthropic
        return u.get("input_tokens", 0), u.get("output_tokens", 0)
    return u.get("prompt_tokens", 0), u.get("completion_tokens", 0)  # OpenAI


def _log_call(kind: str, text: str, context: str | None, out: str, usage: tuple[int, int]) -> None:
    """The raw model answer (pre-unwrap) is the interesting half for prompt testing."""
    line = json.dumps({"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind,
                       "in_text": text, "context": context, "out_text": out,
                       "in": usage[0], "out": usage[1]}, ensure_ascii=False)
    try:
        os.makedirs(os.path.dirname(_CALLS_URL), exist_ok=True)
        with open(_CALLS_URL, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        print(f"call log write failed: {e}", flush=True)


def _call(kind: str, prompt_file: str, text: str, context: str | None,
          max_tokens: int = 1024, note: str | None = None) -> tuple[str | None, tuple[int, int]]:
    """One API call: (result text or None, (input tokens, output tokens))."""
    system = open(os.path.join(_HERE, "prompts", prompt_file)).read()
    if note:
        system += f"\n\n{note}"
    req = _request(os.environ["TUTI_LLM_BASE_URL"], os.environ["TUTI_LLM_MODEL"],
                   os.environ["TUTI_LLM_API_KEY"], system, text, context, max_tokens)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            response = json.load(r)
            out, usage = _text_of(response), _usage_of(response)
    except Exception as e:
        print(f"llm {kind} failed: {e}", flush=True)
        return None, (0, 0)
    _log_call(kind, text, context, out, usage)
    return _unwrap(out) or None, usage


def clean(text: str, context: str | None = None) -> tuple[str | None, tuple[int, int]]:
    """(Cleaned text or None — the caller keeps the raw text then —, token usage).

    context: the previous cleaned segment, sent only for continuity (never rewritten).
    """
    if not configured():
        return None, (0, 0)
    return _call("clean", "clean.md", text, context)


def intent(text: str) -> tuple[dict | None, tuple[int, int]]:
    """A voice command parsed off a final transcript: ({"action": ..., ...} or None, usage).

    None = off, failed, or not JSON — nothing to run. "action":"none" means the transcript
    was plain dictation; the caller decides what to drop.
    """
    if not configured():
        return None, (0, 0)
    # the model has no clock: without today's date it cannot turn «فردا» into an ISO day
    today = datetime.now().strftime("%Y-%m-%d (%A)")
    out, usage = _call("intent", "intent.md", text, context=None, max_tokens=300,
                       note=f"تاریخ امروز: {today}")
    if not out:
        return None, usage
    try:
        parsed = json.loads(out)
    except ValueError:
        print(f"intent was not JSON: {out[:120]!r}", flush=True)
        return None, usage
    if not isinstance(parsed, dict) or not parsed.get("action"):
        return None, usage
    return parsed, usage
