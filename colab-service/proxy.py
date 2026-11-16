"""Authenticated streaming gateway and idle release for the Colab notebook."""
import asyncio
import json
import hashlib
import os
import secrets
import threading
import time
import subprocess
import urllib.request
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import httpx
from recovery import Recovery
from context_guard import fit_context, ContextOverflow
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

BACKEND = os.environ["SERMO_BACKEND"]
KEY = os.environ["SERMO_API_KEY"]
FAMILY = os.environ["SERMO_MODEL_FAMILY"]
DEFAULT_THINKING = os.environ.get("SERMO_THINKING", "true") == "true"
IDLE_SECONDS = int(os.environ["SERMO_IDLE_MINUTES"]) * 60
activity_lock = threading.Lock()
activity = {"last": time.monotonic(), "active": 0}
journal_lock = threading.Lock()
status_path = os.environ.get("SERMO_STATUS_FILE")


def persist_status(event="heartbeat"):
    if not status_path or not journal_lock.acquire(blocking=False):
        return
    try:
        with activity_lock:
            state = {"active_requests": activity["active"],
                     "idle_seconds": round(time.monotonic() - activity["last"], 1)}
        state.update({"recorded_at": datetime.now(timezone.utc).isoformat(), "event": event,
                      "idle_limit_seconds": IDLE_SECONDS, "pid": os.getpid(),
                      "configured_context_length": int(os.environ.get("SERMO_CONTEXT", "0")),
                      "thinking_default": DEFAULT_THINKING})
        try:
            request = urllib.request.Request(BACKEND+'/props',headers={'Authorization':'Bearer '+KEY})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request,timeout=3) as response:
                state['context_length']=json.load(response)['default_generation_settings']['n_ctx']
        except Exception:
            state['context_length']=None
        try:
            gpu = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                                  "--format=csv,noheader"], capture_output=True, text=True, timeout=5)
            if gpu.returncode == 0:
                state["gpu_memory_utilization"] = gpu.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
        target = Path(status_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".tmp")
        with temporary.open("w", encoding="utf-8") as outgoing:
            json.dump(state, outgoing)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        os.replace(temporary, target)
    except OSError:
        print("Runtime status persistence temporarily unavailable", flush=True)
    finally:
        journal_lock.release()


def record_heartbeat():
    while True:
        persist_status()
        time.sleep(30)

allowed = {
    ("GET", "v1/models"),
    ("GET", "health"),
    ("GET", "v1/health"),
    ("POST", "v1/chat/completions"),
    ("POST", "apply-template"),
    ("POST", "tokenize"),
}


def idle_release():
    while True:
        time.sleep(30)
        with activity_lock:
            idle = activity["active"] == 0 and time.monotonic() - activity["last"] >= IDLE_SECONDS
        if not idle:
            continue
        address = os.environ.get("TBE_RUNTIME_ADDR")
        if not address:
            print("自动释放接口不可用，请在 Colab 菜单中手动断开并删除运行时。", flush=True)
            return
        try:
            recorder = threading.Thread(target=persist_status, args=("idle_release_requested",), daemon=True)
            recorder.start()
            recorder.join(timeout=1)
            # This is the runtime management endpoint used by google.colab.runtime.unassign.
            request = urllib.request.Request(f"http://{address}/unassign", data=b"", method="POST")
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=10) as response:
                if response.status == 200:
                    print("闲置时间已到，Colab 已接受释放请求。", flush=True)
                    return
        except Exception:
            print("自动释放暂未成功，稍后重试，也可手动释放运行时。", flush=True)
            time.sleep(30)


@asynccontextmanager
async def lifespan(app):
    app.state.client = httpx.AsyncClient(
        timeout=httpx.Timeout(connect=15, read=120, write=120, pool=15),
        trust_env=False,
    )
    threading.Thread(target=idle_release, daemon=True).start()
    threading.Thread(target=record_heartbeat, daemon=True).start()
    def begin():
        with activity_lock:
            activity['active'] += 1
            activity['last'] = time.monotonic()
    def end():
        with activity_lock:
            activity['active'] -= 1
            activity['last'] = time.monotonic()
    app.state.recovery = Recovery(app.state.client, BACKEND, KEY, begin, end)
    async def clean():
        while True:
            await asyncio.sleep(30)
            app.state.recovery.prune()
    cleaner = asyncio.create_task(clean())
    yield
    cleaner.cancel()
    await asyncio.gather(cleaner, return_exceptions=True)
    await app.state.recovery.close()
    await app.state.client.aclose()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


def format_qwen(body):
    options = body.get("chat_template_kwargs") or {}
    if not isinstance(options, dict):
        raise ValueError("chat_template_kwargs 必须为对象。")
    thinking = options.get("enable_thinking", DEFAULT_THINKING)
    if not isinstance(thinking, bool):
        raise ValueError("思考开关必须为 true 或 false。")
    defaults = {"temperature": 1.0, "top_p": 0.95, "presence_penalty": 0.0}
    if not thinking:
        defaults = {"temperature": 0.7, "top_p": 0.8, "presence_penalty": 1.5}
    defaults.update({"top_k": 20, "min_p": 0.0, "repeat_penalty": 1.0})
    for name, value in defaults.items():
        body.setdefault(name, value)
    return body


def format_gemma(body):
    options = body.get("chat_template_kwargs") or {}
    if not isinstance(options, dict):
        raise ValueError("chat_template_kwargs 必须为对象。")
    thinking = options.get("enable_thinking", DEFAULT_THINKING)
    if not isinstance(thinking, bool):
        raise ValueError("思考开关必须为 true 或 false。")
    messages = body.get("messages")
    if not isinstance(messages, list):
        raise ValueError("messages 必须为数组。")
    # Gemma's embedded template inserts its thinking token and assistant prefix.
    body["chat_template_kwargs"] = dict(options, enable_thinking=thinking)
    body.setdefault("temperature", 1.0)
    body.setdefault("top_p", 0.95)
    body.setdefault("top_k", 64)
    return body


def format_scarlet(body):
    options = body.get("chat_template_kwargs") or {}
    if not isinstance(options, dict):
        raise ValueError("chat_template_kwargs 必须为对象。")
    thinking = options.get("enable_thinking", DEFAULT_THINKING)
    if not isinstance(thinking, bool):
        raise ValueError("思考开关必须为 true 或 false。")
    body["chat_template_kwargs"] = dict(options, enable_thinking=thinking)
    for name, value in {"temperature": 0.6, "top_p": 0.9, "top_k": 20,
                        "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0}.items():
        body.setdefault(name, value)
    return body


@app.api_route("/{path:path}", methods=["GET", "POST", "DELETE"])
async def forward(path: str, request: Request):
    provided = request.headers.get("authorization", "")
    if not secrets.compare_digest(provided.encode("utf-8"), ("Bearer " + KEY).encode("utf-8")):
        return JSONResponse({"error": {"message": "Invalid API Key"}}, status_code=401)
    if request.method == 'GET' and path == 'v1/service-status':
        with activity_lock: active = activity['active']
        return JSONResponse({'active_requests':active,
            'generating_jobs':sum(x.state=='generating' for x in app.state.recovery.jobs.values())})
    if request.method == 'POST' and Path('/content/sermo_colab/maintenance.flag').exists():
        return JSONResponse({'error':{'message':'Model maintenance; retry shortly'}},503)
    recovery_route = path.startswith('v1/requests/') and os.environ.get('SERMO_RECOVERY','1') == '1'
    if recovery_route:
        parts = path.split('/')
        if len(parts) not in (3,4) or not Recovery.valid_id(parts[2]):
            return JSONResponse({'error':'invalid_request_id'},400)
        request_id = parts[2]
        try: after = int(request.query_params.get('after','0'))
        except ValueError: return JSONResponse({'error':'invalid_cursor'},400)
        if request.method == 'GET':
            if len(parts)==4 and parts[3]=='events': return app.state.recovery.stream(request_id,after)
            if len(parts)==3: return app.state.recovery.snapshot(request_id,after)
        if request.method == 'DELETE' and len(parts)==3: return await app.state.recovery.cancel(request_id)
        if request.method != 'POST' or len(parts)!=3:
            return JSONResponse({'error':'unknown_endpoint'},404)
    if not recovery_route and (request.method, path) not in allowed:
        return JSONResponse({"error": {"message": "Unknown endpoint"}}, status_code=404)
    content = await request.body()
    if len(content) > 4 * 1024 * 1024:
        return JSONResponse({"error": {"message": "Request too large"}}, status_code=413)
    if path in {"v1/chat/completions", "apply-template"} or recovery_route:
        try:
            body = json.loads(content)
            if not isinstance(body, dict):
                raise ValueError("请求必须为对象。")
            request_digest = hashlib.sha256(json.dumps(body,sort_keys=True,separators=(',', ':'),ensure_ascii=False).encode()).hexdigest()
            if FAMILY == "gemma":
                body = format_gemma(body)
            elif FAMILY == "scarlet":
                body = format_scarlet(body)
            elif FAMILY == "qwen" and path == "v1/chat/completions":
                body = format_qwen(body)
            if (path == 'v1/chat/completions' or recovery_route) and os.environ.get('SERMO_CONTEXT_GUARD','1')=='1':
                with activity_lock:
                    activity['active'] += 1
                    activity['last'] = time.monotonic()
                try:
                    body, _ = await fit_context(body, app.state.client, BACKEND, KEY)
                finally:
                    with activity_lock:
                        activity['active'] -= 1
                        activity['last'] = time.monotonic()
            content = json.dumps(body, ensure_ascii=False).encode("utf-8")
        except ContextOverflow:
            return JSONResponse({'error':{'code':'context_length_exceeded','message':'System instructions and current turn exceed model context'}},422)
        except (ValueError, TypeError):
            return JSONResponse({"error": {"message": "Invalid chat request"}}, status_code=400)
        except (httpx.HTTPError, KeyError):
            return JSONResponse({'error':{'message':'Colab context preparation unavailable'}},status_code=502)
    if recovery_route:
        return await app.state.recovery.submit(request_id,body,request_digest)
    tracked = path in {"v1/chat/completions", "apply-template", "tokenize"}
    if tracked:
        with activity_lock:
            activity["active"] += 1
            activity["last"] = time.monotonic()
    finished = False

    def finish_request():
        nonlocal finished
        if tracked and not finished:
            finished = True
            with activity_lock:
                activity["active"] -= 1
                activity["last"] = time.monotonic()

    headers = {"Authorization": "Bearer " + KEY, "Accept-Encoding": "identity"}
    for name in ["content-type", "accept"]:
        if value := request.headers.get(name):
            headers[name] = value
    target = BACKEND + "/" + path
    if request.url.query:
        target += "?" + request.url.query
    try:
        outgoing = app.state.client.build_request(request.method, target, content=content, headers=headers)
        response = await app.state.client.send(outgoing, stream=True)
    except (httpx.HTTPError, asyncio.CancelledError):
        finish_request()
        return JSONResponse({"error": {"message": "Colab model server unavailable"}}, status_code=502)

    async def stream():
        try:
            async for chunk in response.aiter_raw():
                yield chunk
        finally:
            finish_request()
            await response.aclose()

    return StreamingResponse(
        stream(),
        status_code=response.status_code,
        headers={
            "Content-Type": response.headers.get("content-type", "application/json"),
            "Cache-Control": "no-store",
            "X-Accel-Buffering": "no",
            "X-Sermo-Recovery": "1" if os.environ.get('SERMO_RECOVERY','1')=='1' else "0",
        },
    )
