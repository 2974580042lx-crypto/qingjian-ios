import argparse
import json
import sys
import time
import requests
from pathlib import Path
from colab_cli.common import state
from colab_cli.contents import ContentsClient

parser = argparse.ArgumentParser()
parser.add_argument("path")
parser.add_argument("--save", type=Path)
args = parser.parse_args()
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
session = state.get_session("easycolab", ignore_missing_session=True)
if session is None:
    raise SystemExit("Existing session not found")
client = ContentsClient(session)
for attempt in range(3):
    try:
        if args.save:
            client.download(args.path, str(args.save))
            print("Saved " + args.save.name)
        else:
            data = client.list_dir(args.path)
        break
    except requests.ConnectionError:
        if attempt == 2:
            raise SystemExit("Cloud connection interrupted after three attempts")
        time.sleep(1)
if not args.save:
    if data.get("type") == "directory":
        print(json.dumps([{key: item.get(key) for key in ["name", "size", "type"]} for item in data.get("content", [])]))
    else:
        print(str(data.get("content", ""))[-2500:])
