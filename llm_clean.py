"""Stage 2: send a raw ASR transcript to an LLM API, get clean Persian back.

Two dialects, picked from the base URL:
  OpenAI-compatible chat/completions — TUTI_LLM_BASE_URL e.g. https://api.openai.com/v1
  Anthropic-compatible messages      — TUTI_LLM_BASE_URL e.g. https://api.z.ai/api/anthropic
                                       (Z.ai coding-plan keys only speak this one)
Config: `.env` in the repo root or the real environment (real environment wins):
  TUTI_LLM_BASE_URL, TUTI_LLM_MODEL (e.g. gpt-4o-mini / glm-5.3-flash), TUTI_LLM_API_KEY
Any of them empty -> cleanup is off. On any failure clean() returns None and the caller
keeps the raw text. Standard library only, so server.py and test_clean.py share it.
"""

import json
import os
import urllib.request

TIMEOUT = 15  # s; a clean that never returns must not pile up

_HERE = os.path.dirname(os.path.abspath(__file__))


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
             context: str | None) -> urllib.request.Request:
    messages = []
    if context:  # the previous cleaned segment: resolves pronouns and ambiguous words across cuts
        messages.append({"role": "user",
                         "content": f"قطعهٔ قبلی گفتار (فقط برای ربط؛ بازنویسیش نکن): {context}"})
    messages.append({"role": "user", "content": text})
    if "anthropic" in base:  # Anthropic protocol: x-api-key, system at top level, content blocks
        url = base.rstrip("/") + "/v1/messages"
        body = {"model": model, "max_tokens": 1024, "temperature": 0,
                "thinking": {"type": "disabled"},  # an editor, not a thinker
                "system": system, "messages": messages}
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    else:  # OpenAI protocol
        url = base if base.endswith("/chat/completions") else base.rstrip("/") + "/chat/completions"
        body = {"model": model, "temperature": 0,
                "messages": [{"role": "system", "content": system}] + messages}
        headers = {"Authorization": f"Bearer {key}"}
    return urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                  headers={"Content-Type": "application/json", **headers})


def _text_of(response: dict) -> str:
    if "choices" in response:  # OpenAI
        return response["choices"][0]["message"]["content"]
    return "".join(b["text"] for b in response.get("content", []) if b.get("type") == "text")


def clean(text: str, context: str | None = None, style: str | None = None) -> str | None:
    """Cleaned text, or None when off or failed — the caller keeps the raw text then.

    context: the previous cleaned segment, sent only for continuity (never rewritten).
    style: "formal" formalizes spoken words; None/"spoken" keeps them as spoken.
    """
    if not configured():
        return None
    system = open(os.path.join(_HERE, "prompts", "clean.md")).read()
    if style == "formal":
        system += "\nسطح کلام را رسمی کن: صورت رسمی کلمات محاوره‌ای (مثل «ازشون» → «از آنها»)."
    req = _request(os.environ["TUTI_LLM_BASE_URL"], os.environ["TUTI_LLM_MODEL"],
                   os.environ["TUTI_LLM_API_KEY"], system, text, context)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            out = _text_of(json.load(r))
    except Exception as e:
        print(f"llm clean failed: {e}", flush=True)
        return None
    return _unwrap(out) or None
