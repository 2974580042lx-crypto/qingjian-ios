"""Notebook cell source. Runs only inside a user-started Google Colab GPU runtime."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.request
from datetime import datetime, timezone

MODEL_OPTIONS = {
    "ScarletKc-2.0 27B": {
        "repo": "bartowski/ScarletKc_ScarletKc-2.0-GGUF",
        "revision": "8f9ec5d386e7a3d434c2b36cea309fcc1828bc1f",
        "file": "ScarletKc_ScarletKc-2.0-Q4_K_M.gguf",
        "size": 17442400640,
        "sha256": "720e9bbf59f3515d542e9717d22099884ceebccc1e1cb39abf78fda0926274ad",
        "alias": "sermo-scarlet-27b",
        "family": "scarlet",
        "cache": "q8_0",
        "large_context_cache": "q4_0",
        "temperature": 0.6,
        "top_p": 0.9,
        "top_k": 20,
    },
    "Qwen3.8-27B 去拒绝版": {
        "repo": "huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF",
        "revision": "1c69098e9c32db6dc06fc48f1d6cc75ad07da89e",
        "file": "Huihui-Qwen3.8-27B-abliterated-UD-DW-Q4_K_M.gguf",
        "size": 16551316384,
        "sha256": "0c7cfe3060493485bb9a6a51195897b0c1d347a49929206adb9a52170183ea03",
        "alias": "sermo-qwen-27b",
        "family": "qwen",
        "cache": "q8_0",
    },
    "Gemma-4-31B 去拒绝版": {
        "repo": "ressl/gemma-4-31B-it-uncensored-GGUF",
        "revision": "91ed8aef47cde5f437e79a9fc1e4e4263afc4c44",
        "file": "gemma-4-31B-it-uncensored-biproj-q4_k_m.gguf",
        "size": 18687062656,
        "sha256": "c28b545304f226cf79408f73115a0c4f5b73a062bdab30b743c5b35cf0c13cba",
        "alias": "sermo-gemma-31b",
        "family": "gemma",
        "cache": "q4_0",
    },
}
ENGINE_TAG = "b12233"
ENGINE_ASSETS = {
    "llama-b12233-bin-ubuntu-cuda-12.8-x64.tar.gz": "92315fbe31bf5d290a27b33d7093661b84221bf132f75dc61a4d928f2e6bcbf9",
    "cudart-llama-b12233-bin-ubuntu-cuda-12.8-x64.tar.gz": "ba3a71df281cab80eb8e4e76a5544a83b5d032b5f836729c56d0613dcf3f4015",
}
WORK = Path("/content/sermo_colab")
PERSIST = Path("/content/drive/MyDrive/EasyColab")


def stop_previous():
    for tunnel in globals().get("_sermo_tunnels", []):
        tunnel.kill()
    for process in reversed(globals().get("_sermo_processes", [])):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(16 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, destination, expected):
    if destination.is_file() and sha256(destination) == expected:
        return
    part = destination.with_suffix(destination.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "Sermo-Colab-Launcher/1.0"})
    with urllib.request.urlopen(request, timeout=90) as source, part.open("wb") as target:
        shutil.copyfileobj(source, target, length=4 * 1024 * 1024)
    if sha256(part) != expected:
        raise RuntimeError("官方组件校验不一致，请稍后重新运行。")
    os.replace(part, destination)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def get_json(url, key, timeout=15):
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + key})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if url.startswith("http://127.0.0.1:") else urllib.request.build_opener()
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


def wait_ready(process, address, key, seconds=600):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("模型启动未完成。请查看下方运行日志。")
        try:
            result = get_json(address + "/health", key)
            if result.get("status") == "ok":
                return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("等待模型加载超时，请查看日志或降低上下文后重试。")


def prepare_engine():
    cache = PERSIST / "cache" / ENGINE_TAG
    install = WORK / ENGINE_TAG
    cache.mkdir(parents=True, exist_ok=True)
    install.mkdir(parents=True, exist_ok=True)
    for name, digest in ENGINE_ASSETS.items():
        archive_path = cache / name
        download(f"https://github.com/ggml-org/llama.cpp/releases/download/{ENGINE_TAG}/{name}", archive_path, digest)
        with tarfile.open(archive_path) as archive:
            for member in archive.getmembers():
                target = (install / member.name).resolve()
                if not target.is_relative_to(install.resolve()):
                    raise RuntimeError("官方程序包包含异常路径。")
                if member.issym() or member.islnk():
                    linked = (target.parent / member.linkname).resolve()
                    if not linked.is_relative_to(install.resolve()):
                        raise RuntimeError("官方程序包包含异常链接。")
            archive.extractall(install, filter="data")
    binary = next(install.rglob("llama-server"), None)
    if binary is None:
        raise RuntimeError("程序包内没有找到 llama-server。")
    binary.chmod(0o755)
    libraries = sorted({str(path.parent) for path in install.rglob("*.so*")})
    libraries += ["/usr/local/cuda/lib64", "/usr/lib/x86_64-linux-gnu"]
    environment = dict(os.environ)
    environment["LD_LIBRARY_PATH"] = ":".join(libraries + [environment.get("LD_LIBRARY_PATH", "")])
    result = subprocess.run([str(binary), "--version"], env=environment, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("推理引擎与当前 Colab 环境不兼容。\n" + result.stderr[-2000:])
    return binary, environment


def stage_model(choice):
    from huggingface_hub import hf_hub_download
    staged = WORK / choice["file"]
    if staged.is_file() and staged.stat().st_size == choice["size"] and sha256(staged) == choice["sha256"]:
        return staged
    model_folder = PERSIST / "models" / choice["family"]
    model_folder.mkdir(parents=True, exist_ok=True)
    cached = model_folder / choice["file"]
    if not cached.is_file() or cached.stat().st_size != choice["size"]:
        print("首次下载模型到 Google Drive，请等待下载完成。", flush=True)
        hf_hub_download(choice["repo"], choice["file"], revision=choice["revision"], local_dir=str(model_folder))
    if shutil.disk_usage(WORK).free < choice["size"] + 2 * 1024**3:
        raise RuntimeError("当前 Colab 运行盘空间不足，请分配有更多磁盘空间的运行环境。")
    print("正在把模型载入云端运行盘并核对文件，请等待。", flush=True)
    part = staged.with_suffix(".gguf.part")
    digest = hashlib.sha256()
    with cached.open("rb") as source, part.open("wb") as target:
        for block in iter(lambda: source.read(16 * 1024 * 1024), b""):
            target.write(block)
            digest.update(block)
    if digest.hexdigest() != choice["sha256"]:
        raise RuntimeError("云盘模型文件校验失败，请重新下载这个模型文件后再运行。")
    os.replace(part, staged)
    return staged


def launch():
    if not Path("/content/drive/MyDrive").is_dir():
        raise RuntimeError("请先运行上面的云盘授权单元格。")
    gpu = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"], text=True
    ).strip()
    supported = ["L4", "A100", "H100", "PRO 6000", "BLACKWELL"]
    if not any(name in gpu.upper() for name in supported):
        raise RuntimeError("请在 Colab 的运行时设置里选择 L4、A100、H100 或 G4，再重新运行。当前显卡为 " + gpu)
    print("当前云端显卡及显存（MiB）为 " + gpu, flush=True)
    if MODEL not in MODEL_OPTIONS:
        raise RuntimeError("请在上面的模型选项中选择已配置的模型。")
    if CONTEXT not in [16384, 32768, 65536, 131072, 262144]:
        raise RuntimeError("请选择 16K、32K、64K、128K 或 256K 上下文。")
    if not 15 <= IDLE_MINUTES <= 240:
        raise RuntimeError("闲置释放时间请设在 15 到 240 分钟。")
    stop_previous()
    globals()["_sermo_processes"] = []
    globals()["_sermo_tunnels"] = []
    choice = MODEL_OPTIONS[MODEL]
    WORK.mkdir(parents=True, exist_ok=True)
    PERSIST.mkdir(parents=True, exist_ok=True)
    endpoint_file = PERSIST / "endpoint.json"
    key = ""
    if endpoint_file.is_file():
        try:
            old = json.loads(endpoint_file.read_text(encoding="utf-8"))
            saved_key = old.get("api_key", "")
            if isinstance(saved_key, str) and 24 <= len(saved_key) <= 256 and "\n" not in saved_key:
                key = saved_key
        except (ValueError, OSError):
            pass
    key = key or secrets.token_urlsafe(32)
    key_file = WORK / "api-key.txt"
    key_file.write_text(key, encoding="utf-8")
    key_file.chmod(0o600)
    print("正在准备云端推理引擎。", flush=True)
    binary, environment = prepare_engine()
    model_path = stage_model(choice)
    model_port = free_port()
    proxy_port = free_port()
    while proxy_port == model_port:
        proxy_port = free_port()
    backend = f"http://127.0.0.1:{model_port}"
    qwen_thinking = choice["family"] == "qwen" and THINKING
    gemma = choice["family"] == "gemma"
    cache_type = choice.get("large_context_cache", choice["cache"]) if CONTEXT >= 131072 else choice["cache"]
    commands = [
        str(binary), "-m", str(model_path), "--host", "127.0.0.1", "--port", str(model_port),
        "--alias", choice["alias"], "--api-key-file", str(key_file),
        "-ngl", "999", "-c", str(CONTEXT), "-np", "1", "-b", "512", "-ub", "128",
        "-fa", "on", "--cache-type-k", cache_type, "--cache-type-v", cache_type,
        "--sse-ping-interval", "10",
        "--jinja", "--reasoning-format", "deepseek", "--reasoning", "auto",
        "--chat-template-kwargs", json.dumps({"enable_thinking": THINKING}),
        "--reasoning-effort", "medium",
        "--temp", str(choice.get("temperature", 1.0 if gemma or qwen_thinking else 0.7)),
        "--top-p", str(choice.get("top_p", 0.95 if gemma or qwen_thinking else 0.8)),
        "--top-k", str(choice.get("top_k", 64 if gemma else 20)), "--min-p", "0.0",
    ]
    log_path = WORK / "model.log"
    log = log_path.open("w", encoding="utf-8")
    model_process = subprocess.Popen(commands, env=environment, stdout=log, stderr=subprocess.STDOUT)
    globals()["_sermo_processes"].append(model_process)
    print(f"正在加载 {MODEL}，上下文 {CONTEXT // 1024}K。", flush=True)
    try:
        wait_ready(model_process, backend, key)
        properties = get_json(backend + "/props", key)
        actual_context = properties.get("default_generation_settings", {}).get("n_ctx", 0)
        if actual_context < CONTEXT:
            raise RuntimeError(f"实际上下文仅为 {actual_context}，没有达到请求的 {CONTEXT}，不会发布不匹配的地址。")
        proxy_path = WORK / "sermo_proxy.py"
        proxy_path.write_text(PROXY_SOURCE, encoding="utf-8")
        proxy_environment = dict(os.environ)
        proxy_environment.update({
            "SERMO_BACKEND": backend,
            "SERMO_API_KEY": key,
            "SERMO_MODEL_FAMILY": choice["family"],
            "SERMO_THINKING": "true" if THINKING else "false",
            "SERMO_IDLE_MINUTES": str(IDLE_MINUTES),
            "SERMO_CONTEXT": str(CONTEXT),
            "SERMO_STATUS_FILE": str(PERSIST / "diagnostics" /
                ("runtime-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json")),
        })
        proxy_log = (WORK / "gateway.log").open("w", encoding="utf-8")
        proxy = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "sermo_proxy:app", "--app-dir", str(WORK),
             "--host", "127.0.0.1", "--port", str(proxy_port), "--no-access-log", "--log-level", "warning"],
            env=proxy_environment, stdout=proxy_log, stderr=subprocess.STDOUT,
        )
        globals()["_sermo_processes"].append(proxy)
        wait_ready(proxy, f"http://127.0.0.1:{proxy_port}", key, seconds=60)
        from gradio.networking import setup_tunnel
        from gradio.tunneling import CURRENT_TUNNELS
        print("正在建立手机访问地址。", flush=True)
        before = len(CURRENT_TUNNELS)
        try:
            public = setup_tunnel("127.0.0.1", proxy_port, secrets.token_urlsafe(24), None, None)
        finally:
            globals()["_sermo_tunnels"] = CURRENT_TUNNELS[before:]
        public = public.rstrip("/")
        if not public.startswith("https://"):
            raise RuntimeError("隧道没有生成有效的 HTTPS 地址。")
        # Publish only after the authenticated public API responds with the actual model alias.
        ready = False
        for attempt in range(10):
            try:
                models = get_json(public + "/v1/models", key, timeout=20)
                ready = any(item.get("id") == choice["alias"] for item in models.get("data", []))
                if ready:
                    break
            except Exception:
                pass
            time.sleep(3)
        if not ready:
            raise RuntimeError("模型已加载，但公网连接暂未就绪，请稍后重新运行启动单元格。")
        endpoint = {
            "base_url": public + "/v1",
            "api_key": key,
            "model": choice["alias"],
            "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "context_length": CONTEXT,
            "thinking_default": THINKING,
        }
        temporary = endpoint_file.with_name("endpoint.json.tmp")
        temporary.write_text(json.dumps(endpoint, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, endpoint_file)
        print("\n模型已就绪，云盘 /EasyColab/endpoint.json 已更新。")
        print(f"手机 Sermo 选择 Colab，从 Drive 刷新。最大上下文选择 {CONTEXT}，思考选择{'开启' if THINKING else '关闭'}。")
        print(f"闲置 {IDLE_MINUTES} 分钟后请求释放 Colab，正在输出时继续运行。")
        print("聊天结束时，也可以在 Colab 菜单中断开连接并删除运行时。")
    except BaseException:
        stop_previous()
        if log_path.is_file():
            print("模型日志末尾\n" + log_path.read_text(encoding="utf-8", errors="replace")[-5000:])
        raise


launch()
