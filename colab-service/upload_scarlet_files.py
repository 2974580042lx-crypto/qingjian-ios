"""Upload local serving files without executing or queuing work in the kernel."""
import json
import sys
from pathlib import Path
import requests
from colab_cli.common import state
from colab_cli.contents import ContentsClient

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
session = state.get_session("easycolab", ignore_missing_session=True)
if session is None:
    raise SystemExit("Existing session required; nothing allocated")
client = ContentsClient(session)
try:
    client.list_dir("/content/sermo_colab")
except FileNotFoundError:
    client._request("PUT", "/content/sermo_colab", json_data={"type": "directory"})
try:
    for name in ["launcher.py", "proxy.py", "workbench_run.py", "workbench_run_eos_trial.py", "recovery.py", "context_guard.py"]:
        client.upload(str(Path(__file__).parent / name), "/content/sermo_colab/" + name)
        print("Uploaded " + name, flush=True)
except requests.RequestException as error:
    status = error.response.status_code if error.response is not None else "connection failure"
    raise SystemExit(f"Serving file upload failed: {status}; credentials omitted") from None
print(json.dumps({"files_uploaded": True, "context_target": 262144}))
