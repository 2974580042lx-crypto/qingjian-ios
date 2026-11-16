"""Request the supervisor to reload only the model on an existing idle runtime."""
import argparse
import json
from pathlib import Path
import time
from colab_cli.common import state
from colab_cli.contents import ContentsClient

p=argparse.ArgumentParser();p.add_argument('--context',type=int,choices=[98304,131072,262144],required=True)
p.add_argument('--cache',choices=['q4_0','q8_0'],required=True);args=p.parse_args()
s=state.get_session('easycolab',ignore_missing_session=True)
if s is None:raise SystemExit('Existing runtime required; no allocation performed')
c=ContentsClient(s);root=Path(__file__).parent
command=root/'private/reload-model.json'
command.write_text(json.dumps({'context':args.context,'cache':args.cache}))
c.upload(str(command),'/content/sermo_colab/reload-model.json')
started=time.monotonic()
for _ in range(80):
    try:
        value=json.loads(c.list_dir('/content/sermo_colab/reload-result.json')['content'])
        if value.get('context')==args.context and value.get('cache')==args.cache:
            value['observed_wall_seconds']=round(time.monotonic()-started,2)
            (root/'logs'/f'reload-{args.context}-{args.cache}-20261116.json').write_text(json.dumps(value,indent=2))
            print(json.dumps(value))
            if not value.get('success'):raise SystemExit('Reload failed; supervisor attempted rollback')
            break
    except FileNotFoundError:pass
    time.sleep(2)
else:raise SystemExit('Reload result not confirmed; inspect existing runtime, do not allocate another')
