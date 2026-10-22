#!/usr/bin/env python3
"""Small OpenAI-compatible OmniRoute caller for ai-conductor (no extra packages)."""
import json
import os
import sys
import urllib.error
import urllib.request

def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: omniroute_call.py <route> <prompt-file>", file=sys.stderr)
        return 2
    route, prompt_path = sys.argv[1:]
    if not route or "/" in route or any(ch.isspace() for ch in route):
        print("Invalid OmniRoute alias", file=sys.stderr)
        return 2
    key = (os.getenv("OMNIROUTE_API_KEY") or os.getenv("OMNIROUTE_KEY")
           or os.getenv("LITELLM_MASTER_KEY"))
    if not key:
        print("OmniRoute key not configured", file=sys.stderr)
        return 2
    base = os.getenv("OMNIROUTE_BASE_URL", "http://127.0.0.1:20128/v1").rstrip("/")
    if not (base.startswith("http://") or base.startswith("https://")):
        print("Invalid OmniRoute base URL", file=sys.stderr)
        return 2
    with open(prompt_path, encoding="utf-8") as f:
        prompt = f.read()
    data = json.dumps({"model": route, "messages": [{"role": "user", "content": prompt}],
                       "temperature": 0.3}).encode("utf-8")
    req = urllib.request.Request(
        base + "/chat/completions", data=data,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=int(os.getenv("DEBATE_TIMEOUT", "45"))) as res:
            payload = json.load(res)
        content = payload["choices"][0]["message"]["content"]
        if not isinstance(content, str) or not content.strip():
            raise ValueError("empty model response")
        print(content.strip())
        return 0
    except (urllib.error.HTTPError, urllib.error.URLError, KeyError, IndexError,
            ValueError, TimeoutError) as e:
        # Never print request headers, response bodies or credentials.
        print("OmniRoute request failed: " + type(e).__name__, file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
