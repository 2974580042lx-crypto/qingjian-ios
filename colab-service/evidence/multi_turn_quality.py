"""Generated neutral multi-turn histories, never private conversations."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_profiles import collect, make_body, ROOT

parser=argparse.ArgumentParser()
parser.add_argument('--endpoint',type=Path,required=True)
parser.add_argument('--minutes',type=float,default=10)
parser.add_argument('--label',default='cache-on')
args=parser.parse_args()
endpoint=json.loads(args.endpoint.read_text(encoding='utf-8'))
plan=json.loads((ROOT/'experiment-plan.json').read_text(encoding='utf-8'))
plan['shared_test_settings']['cache_prompt']=True
profiles={p['name']:p for p in plan['profiles']}
folder=ROOT/'results'/('multiturn-'+args.label+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
folder.mkdir(parents=True)
deadline=time.monotonic()+args.minutes*60
questions=['雨下得好大，我推门进了书店，收起伞。',
           '我想找一本读起来轻松的书，最近工作有点累。',
           '好，就这本。你这里几点关门？',
           '谢谢，下次见。']
fixtures=json.loads((ROOT/'neutral-cases.json').read_text(encoding='utf-8'))
background=next(x for x in fixtures if x['id']=='long_context_scene')['messages'][0]['content']
for name in ['B_author_baseline_no_eos_bias','A_current_control']:
    messages=[{'role':'system','content':'你扮演成年书店店员沈宁，我扮演成年顾客。只写店员的言行，不替顾客决定行动，不抢顾客台词。书店每天晚上八点关门，现在是下午三点。回应当前场景，让对话自然进行；根据问题决定篇幅，不要求固定字数。'}]
    messages[0]['content']+='\n\n以下为稳定背景资料，仅在相关时引用：\n'+background
    for turn,question in enumerate(questions):
        if time.monotonic()>=deadline:break
        messages.append({'role':'user','content':question})
        body=make_body(plan,profiles[name],{'messages':messages},endpoint['model'],17,16384)
        body['cache_prompt']=turn>0
        result=collect(endpoint,body,min(deadline,time.monotonic()+120))
        result.update(profile=name,turn=turn,user=question,case='generated_neutral_bookshop')
        (folder/(name+'-'+str(turn)+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps({k:result.get(k) for k in ['profile','turn','characters','finish_reasons','censored','error_type','timings']}),flush=True)
        if not result['protocol_complete']:break
        messages.append({'role':'assistant','content':result['text']})
