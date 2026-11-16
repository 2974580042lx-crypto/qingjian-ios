"""Start the Sermo gateway on a VM already allocated by EasyColab."""
from pathlib import Path
import os
import signal
import time
import json
import threading
from datetime import datetime, timezone

work = Path("/content/sermo_colab")
work.mkdir(parents=True, exist_ok=True)
source = (work / "launcher.py").read_text(encoding="utf-8")
source = source.rsplit("\nlaunch()", 1)[0]
source = source.replace(
    'if not Path("/content/drive/MyDrive").is_dir():',
    'if not PERSIST.parent.is_dir():',
)
scope = {"__name__": "sermo_workbench"}
exec(compile(source, "sermo_launcher", "exec"), scope)
scope.update({
    "MODEL": "ScarletKc-2.0 27B",
    "CONTEXT": 262144,
    "THINKING": False,
    "IDLE_MINUTES": 60,
    "PERSIST": Path("/content/sermo_drive/MyDrive/EasyColab"),
    "PROXY_SOURCE": (work / "proxy.py").read_text(encoding="utf-8"),
})
scope["launch"]()
(work / "service.ready").write_text("ready")


def shutdown(signum, frame):
    (work / "service.ready").unlink(missing_ok=True)
    scope["stop_previous"]()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, shutdown)
while True:
    time.sleep(15)
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
