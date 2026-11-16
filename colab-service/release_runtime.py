import json
import sys
import time
from colab_cli.common import state
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
session = state.store.get("easycolab")
adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, allowed_methods=["GET", "POST"]))
state.client.session.mount("https://", adapter)
if session:
    state.client.unassign(session.endpoint)
    print("已发送本次 L4 的释放请求", flush=True)
    for attempt in range(10):
        active = state.client.list_assignments()
        if not any(item.endpoint == session.endpoint for item in active):
            state.store.remove(session.name)
            break
        time.sleep(2)
    else:
        raise SystemExit("释放请求已发送，实例仍在结束中")
info = state.client.get_consumption_user_info()
print(json.dumps({
    "active_assignments": int(info.assignments_count),
    "burn_rate_cu_hour": round(float(info.consumption_rate_hourly), 2),
    "remaining_cu": round(float(info.paid_compute_units_balance), 2),
}, ensure_ascii=False))
