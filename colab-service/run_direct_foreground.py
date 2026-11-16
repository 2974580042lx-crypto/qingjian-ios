"""Run the real serving workload in an executing Colab cell, not a detached job."""
import json
import sys
import uuid
import os
from datetime import datetime, timezone
from pathlib import Path
from colab_cli.common import state
from colab_cli.runtime import ColabRuntime

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
session = state.get_session("easycolab", ignore_missing_session=True)
if session is None:
    raise SystemExit("Existing authorized runtime is required; no GPU was allocated")

def remember_kernel(kernel_id):
    session.kernel_id = kernel_id
    state.store.add(session)

def show_output(output):
    if output.get("text"):
        print(output["text"], end="", flush=True)
    if output.get("output_type") == "error":
        print(output.get("ename", "Error"), output.get("evalue", ""), flush=True)

runtime = ColabRuntime(session.url, session.token, kernel_id=session.kernel_id,
    session_id=uuid.uuid4().hex, on_kernel_started=remember_kernel)
controller = Path(__file__).parent / "private/foreground-controller.json"
controller.write_text(json.dumps({"pid": os.getpid(), "created_at": datetime.now(timezone.utc).isoformat(),
                                  "runtime_endpoint": session.endpoint}), encoding="utf-8")
print(json.dumps({"serving_mode": "executing_colab_cell", "accelerator": session.accelerator}), flush=True)
source = (Path(__file__).parent / "workbench_run_direct.py").read_text(encoding="utf-8")
try:
    runtime.execute_code(source, timeout=43200, output_hook=show_output)
finally:
    runtime.stop(shutdown_kernel=False)
