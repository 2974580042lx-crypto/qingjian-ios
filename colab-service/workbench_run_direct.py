"""Start the Sermo gateway on a VM already allocated by EasyColab."""
from pathlib import Path
import os
import signal
import time
import json
import threading
import subprocess
from datetime import datetime, timezone

work = Path("/content/sermo_colab")
work.mkdir(parents=True, exist_ok=True)
boot_started = time.monotonic()
boot_metrics = {'started_at':datetime.now(timezone.utc).isoformat()}
source = (work / "launcher.py").read_text(encoding="utf-8")
source = source.rsplit("\nlaunch()", 1)[0]
source = source.replace(
    'if not Path("/content/drive/MyDrive").is_dir():',
    'if not PERSIST.parent.is_dir():',
)
source = source.replace("模型已就绪，云盘 /EasyColab/endpoint.json 已更新。", "模型已就绪，连接文件保存在运行盘；本次没有更新 Drive。")
source = source.replace("手机 Sermo 选择 Colab，从 Drive 刷新。", "手机 Sermo 选择 Colab，手动填写新 Base URL。")
scope = {"__name__": "sermo_workbench"}
exec(compile(source, "sermo_launcher", "exec"), scope)
scope.update({
    "MODEL": "ScarletKc-2.0 27B",
    "CONTEXT": int(os.environ.get('SERMO_TEST_CONTEXT','262144')),
    "THINKING": False,
    "IDLE_MINUTES": 60,
    "PERSIST": Path("/content/sermo_colab/direct-state"),
    "PROXY_SOURCE": (work / "proxy.py").read_text(encoding="utf-8"),
})
def direct_stage(choice):
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    boot_metrics['engine_ready_seconds']=round(time.monotonic()-boot_started,3)
    from huggingface_hub import hf_hub_download
    download_started=time.monotonic()
    model = Path(hf_hub_download(choice["repo"], choice["file"], revision=choice["revision"], local_dir=str(work), token=False))
    boot_metrics['download_seconds']=round(time.monotonic()-download_started,3)
    verify_started=time.monotonic()
    if model.stat().st_size != choice["size"] or scope["sha256"](model) != choice["sha256"]:
        raise RuntimeError("Direct download verification failed")
    boot_metrics['sha256_seconds']=round(time.monotonic()-verify_started,3)
    (work/'boot-metrics.json').write_text(json.dumps(boot_metrics))
    print("Direct model download verified", flush=True)
    return model
scope["stage_model"] = direct_stage
scope["PERSIST"].mkdir(parents=True, exist_ok=True)
seed = work / "endpoint-seed.json"
if seed.exists():
    (scope["PERSIST"] / "endpoint.json").write_bytes(seed.read_bytes())
if os.environ.get('SERMO_LEGACY_EOS_BIAS','0') == '1':
    patch = (work / "workbench_run_eos_trial.py").read_text().split("_normal=",1)[0]
    patch_scope = {}
    exec(patch, patch_scope)
    scope["PROXY_SOURCE"] = patch_scope["_eos_trial_proxy"](scope["PROXY_SOURCE"])
print("Direct online deployment; Google Drive is not mounted", flush=True)
scope["launch"]()
boot_metrics['ready_seconds']=round(time.monotonic()-boot_started,3)
(work/'boot-metrics.json').write_text(json.dumps(boot_metrics))
print("Direct endpoint saved on runtime disk; Drive endpoint has NOT been updated.", flush=True)
(work / "service.ready").write_text("ready")


def shutdown(signum, frame):
    (work / "service.ready").unlink(missing_ok=True)
    scope["stop_previous"]()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, shutdown)
while True:
    time.sleep(2)
    command_path = work / 'reload-model.json'
    if command_path.exists():
        # This control file is accessible only through the authenticated runtime,
        # not through the public phone gateway. Retain proxy, API key and tunnel.
        command = json.loads(command_path.read_text())
        requested_context = int(command.get('context',0))
        cache = command.get('cache')
        if requested_context not in (98304,131072,262144) or cache not in ('q4_0','q8_0'):
            command_path.unlink()
            print('Rejected invalid model reload configuration',flush=True)
            continue
        processes = scope['_sermo_processes']
        old = processes[0]
        args = list(old.args)
        original_args = list(args)
        backend = 'http://127.0.0.1:' + args[args.index('--port')+1]
        key = (work/'api-key.txt').read_text().strip()
        maintenance = work/'maintenance.flag'
        maintenance.touch()
        proxy_args=list(processes[1].args)
        proxy_address='http://127.0.0.1:'+proxy_args[proxy_args.index('--port')+1]
        status=scope['get_json'](proxy_address+'/v1/service-status',key)
        if status['active_requests'] or status['generating_jobs']:
            continue
        slots = scope['get_json'](backend+'/slots',key)
        if any(s.get('is_processing') for s in slots):
            continue
        command_path.unlink()
        environment=dict(item.split('=',1) for item in Path(f'/proc/{old.pid}/environ').read_text().split('\0') if '=' in item)
        old.terminate()
        try: old.wait(timeout=15)
        except subprocess.TimeoutExpired: old.kill();old.wait(timeout=5)
        for flag,value in [('-c',str(requested_context)),('--cache-type-k',cache),('--cache-type-v',cache)]:
            args[args.index(flag)+1]=value
        started = time.monotonic()
        replacement = subprocess.Popen(args,env=environment,
            stdout=(work/'model.log').open('a'),stderr=subprocess.STDOUT)
        processes[0] = replacement
        try:
            scope['wait_ready'](replacement,backend,key,seconds=120)
            actual=scope['get_json'](backend+'/props',key)['default_generation_settings']['n_ctx']
            (work/'reload-result.json').write_text(json.dumps({'context':actual,'cache':cache,
                'seconds':round(time.monotonic()-started,2),'success':actual==requested_context}))
            print('Model-only reload complete; gateway and tunnel retained',flush=True)
        except Exception:
            if replacement.poll() is None:
                replacement.kill();replacement.wait(timeout=5)
            fallback=subprocess.Popen(original_args,env=environment,
                stdout=(work/'model.log').open('a'),stderr=subprocess.STDOUT)
            processes[0]=fallback
            scope['wait_ready'](fallback,backend,key,seconds=120)
            (work/'reload-result.json').write_text(json.dumps({'success':False,'context':requested_context,'cache':cache}))
        finally:
            maintenance.unlink(missing_ok=True)
    if any(process.poll() is not None for process in scope["_sermo_processes"]):
        def record_exit():
            try:
                target = scope["PERSIST"] / "diagnostics" / ("service-exit-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(json.dumps({"recorded_at": datetime.now(timezone.utc).isoformat(),
                    "reason": "owned_child_process_exited", "children": [
                        {"pid": process.pid, "returncode": process.poll()} for process in scope["_sermo_processes"]]}))
            except OSError:
                pass
        recorder = threading.Thread(target=record_exit, daemon=True)
        recorder.start()
        recorder.join(timeout=1)
        shutdown(None, None)
