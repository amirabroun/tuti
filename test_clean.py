# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Quick check of stage 2 without the ASR model or the app:

    uv run test_clean.py                       # one hard-coded raw sentence
    uv run test_clean.py "متن خام دلخواه"      # your own

Prints raw vs clean, or explains what's missing. Exit 1 = cleaning off or failed.
"""

import argparse

import llm_clean

RAW = "سلام خوبی چه خبر یه تست میکنم ببینم چطوره"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default=RAW, help="raw text to clean (default: a sample)")
    ap.add_argument("--context", default=None, help="previous cleaned segment, sent for continuity")
    a = ap.parse_args()
    llm_clean.load_env()
    if not llm_clean.configured():
        print("cleaning is off: fill TUTI_LLM_BASE_URL, TUTI_LLM_MODEL and TUTI_LLM_API_KEY in .env")
        raise SystemExit(1)
    print(f"raw:     {a.text}")
    print(f"context: {a.context or '-'}")
    cleaned, (tok_in, tok_out) = llm_clean.clean(a.text, context=a.context)
    if cleaned:
        print(f"clean:  {cleaned}")
        print(f"tokens: {tok_in} in / {tok_out} out")
    else:
        print("clean failed (see the error above); check .env values and the API")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
