"""Allocate only an L4 on the explicitly selected account; reuse our session."""
import json
from colab_cli.auth import get_credentials
from colab_cli.common import state
from colab_cli.commands.session import new

expected_account = "songt2363@gmail.com"
client = get_credentials()
identity = client.get("https://www.googleapis.com/oauth2/v2/userinfo", timeout=20)
identity.raise_for_status()
if identity.json().get("email") != expected_account:
    raise SystemExit("Account differs from the account authorized for this deployment")
assignments = state.client.list_assignments()
known = state.store.get("easycolab")
if known and any(item.endpoint == known.endpoint for item in assignments):
    if known.accelerator != "L4":
        raise SystemExit("Existing EasyColab session is not L4; no allocation was made")
    print(json.dumps({"reused": True, "accelerator": known.accelerator}))
elif assignments:
    raise SystemExit("Other live assignments exist; inspect their ownership before allocating")
else:
    if known:
        state.store.remove("easycolab")
    new(session="easycolab", gpu="L4", tpu=None, high_mem=False)
info = state.client.get_consumption_user_info()
print(json.dumps({"remaining_cu": info.paid_compute_units_balance,
                  "burn_rate_cu_h": info.consumption_rate_hourly,
                  "assignments": info.assignments_count}))
