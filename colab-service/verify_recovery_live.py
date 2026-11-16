"""Exercise disconnect/recovery against our live service using neutral text only."""
import json
from pathlib import Path
import time
import uuid
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

client=requests.Session()
client.mount('https://',HTTPAdapter(max_retries=Retry(total=3,backoff_factor=.5,
    allowed_methods=['GET','POST','DELETE'],status_forcelist=[502,503,504])))

root=Path(__file__).parent
e=json.loads((root/'private/endpoint.json').read_text(encoding='utf-8'))
h={'Authorization':'Bearer '+e['api_key']}
base=e['base_url']
model=client.get(base+'/models',headers=h,timeout=20)
assert model.status_code==200 and model.headers.get('X-Sermo-Recovery')=='1'
body={'model':e['model'],'stream':True,'max_tokens':16384,'chat_template_kwargs':{'enable_thinking':False},
      'messages':[{'role':'user','content':'请用一小段中文介绍雨后散步的感觉，最后写【验证结束】。'}]}
name=uuid.uuid4().hex;url=base+'/requests/'+name
assert client.get(url,timeout=20).status_code==401
started=time.monotonic()
assert client.post(url,headers=h,json=body,timeout=45).status_code==202
first=None;cursor=0;answer='';done=False;reasons=[]
def accept(data):
    global answer,done,cursor
    cursor+=1
    if data=='[DONE]':done=True;return
    parsed=json.loads(data)
    for x in parsed.get('choices',[]):
        answer+=x.get('delta',{}).get('content') or ''
        if x.get('finish_reason'):reasons.append(x['finish_reason'])
with client.get(url+'/events',headers=h,stream=True,timeout=(15,30)) as response:
    response.raise_for_status()
    for line in response.iter_lines(chunk_size=1):
        if line.startswith(b'data: '):
            accept(line[6:].decode())
            if answer:
                first=time.monotonic()-started
                break
disconnected_cursor=cursor
assert client.post(url,headers=h,json=body,timeout=45).status_code==202
assert client.post(url,headers=h,json={**body,'seed':123},timeout=45).status_code==409
time.sleep(2)
for _ in range(180):
    r=client.get(url,headers=h,params={'after':cursor},timeout=15);r.raise_for_status();snap=r.json()
    expected=cursor+len(snap['events'])
    for data in snap['events']:accept(data)
    assert cursor==expected==snap['next_cursor']
    if snap['state']!='generating' and not snap['has_more']:break
    time.sleep(.5)
assert snap['state']=='completed' and done and 'stop' in reasons and '【验证结束】' in answer
assert client.get(url,headers=h,params={'after':cursor},timeout=15).json()['events']==[]
cancel_id=uuid.uuid4().hex;cancel_url=base+'/requests/'+cancel_id
assert client.post(cancel_url,headers=h,json=body,timeout=45).status_code==202
c=client.delete(cancel_url,headers=h,timeout=20);c.raise_for_status()
assert c.json()['state'] in ('cancelled','completed')
report={'disconnect_recovery_passed':True,'unauthorized_denied':True,'idempotent_resubmit':True,
        'timing_origin':'before_initial_job_submission',
        'conflicting_id_rejected':True,'cursor_no_duplicate':True,'cancel_state':c.json()['state'],
        'first_content_seconds':round(first,3),'total_seconds':round(time.monotonic()-started,3),
        'disconnected_after_events':disconnected_cursor,'final_events':cursor,
        'finish_reasons':reasons,'done':done,'neutral_answer':answer}
(root/'logs/recovery-live-20261116.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False))
