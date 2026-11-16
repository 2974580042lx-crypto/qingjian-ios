"""Verify the actual public SSE path without exposing the connection key."""
import json
from pathlib import Path
import time
import requests
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

path = Path(__file__).parent / "private/endpoint.json"
endpoint = json.loads(path.read_text(encoding="utf-8"))
headers = {"Authorization": "Bearer " + endpoint["api_key"]}
base = endpoint["base_url"]
models = requests.get(base + "/models", headers=headers, timeout=30)
models.raise_for_status()
ids = [item.get("id") for item in models.json().get("data", [])]
if endpoint["model"] not in ids:
    raise RuntimeError("Public API does not expose the deployed model")
unauth = requests.get(base + "/models", timeout=20)
if unauth.status_code != 401:
    raise RuntimeError("Public API authentication check failed")
root = base.removesuffix("/v1")
template = requests.post(root + "/apply-template", headers=headers, json={
    "messages": [{"role": "user", "content": "你好"}],
    "chat_template_kwargs": {"enable_thinking": False},
}, timeout=30)
template.raise_for_status()
prompt = template.json()["prompt"]
tokens = requests.post(root + "/tokenize", headers=headers,
    json={"content": prompt, "add_special": True, "parse_special": True}, timeout=30)
tokens.raise_for_status()
token_count = len(tokens.json()["tokens"])
started = time.monotonic()
first = None
answer = ""
reasoning = ""
done = False
body = {
    "model": endpoint["model"], "stream": True, "max_tokens": 96,
    "chat_template_kwargs": {"enable_thinking": False},
    "messages": [{"role": "user", "content": "请用一句自然的中文打个招呼，不用解释你的身份。"}],
}
with requests.post(base + "/chat/completions", headers=headers, json=body,
                   stream=True, timeout=(20, 120)) as response:
    response.raise_for_status()
    if "text/event-stream" not in response.headers.get("content-type", ""):
        raise RuntimeError("Expected an SSE response")
    for line in response.iter_lines():
        if not line.startswith(b"data: "):
            continue
        value = line[6:]
        if value == b"[DONE]":
            done = True
            break
        payload = json.loads(value)
        for choice in payload.get("choices", []):
            delta = choice.get("delta", {})
            chunk = delta.get("content") or ""
            if chunk and first is None:
                first = time.monotonic() - started
            answer += chunk
            reasoning += delta.get("reasoning_content") or ""
if not answer.strip() or not done or reasoning or "<think>" in answer:
    raise RuntimeError("Stream content or disabled-thinking verification failed")
report = {"public_models": ids, "unauthenticated_status": unauth.status_code,
                  "template_tokens": token_count,
                  "sse_done": done, "first_content_seconds": round(first, 2),
                  "total_seconds": round(time.monotonic()-started, 2),
                  "reasoning_chars": len(reasoning), "reply": answer}
report_path = Path(__file__).parent / "logs/scarlet-deployment-verification-20261115.json"
report_path.parent.mkdir(exist_ok=True)
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False))
