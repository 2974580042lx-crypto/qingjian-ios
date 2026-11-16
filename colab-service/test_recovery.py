import asyncio
import json
import unittest
import os
import httpx
from recovery import Recovery
from context_guard import fit_context, ContextOverflow


class Stream(httpx.AsyncByteStream):
    def __init__(self, release, incomplete=False): self.release,self.incomplete=release,incomplete
    async def __aiter__(self):
        yield b'data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}\n\n'
        await self.release.wait()
        if not self.incomplete:
            payload='data: '+json.dumps({'choices':[{'delta':{'content':'世界'},'finish_reason':'stop'}]},ensure_ascii=False)+'\n\n'
            encoded=payload.encode()
            for i in range(0,len(encoded),3): yield encoded[i:i+3]
            yield b'data: [DONE]\n\n'


class RecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.release=asyncio.Event();self.calls=0;self.active=0;self.incomplete=False
        def handler(request):
            self.calls+=1
            self.assertEqual(request.headers['authorization'],'Bearer fake-test-key')
            return httpx.Response(200,headers={'content-type':'text/event-stream'},stream=Stream(self.release,self.incomplete))
        self.client=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        def begin(): self.active+=1
        def end(): self.active-=1
        self.pool=Recovery(self.client,'http://test','fake-test-key',begin,end,max_jobs=2)
        self.name='synthetic-request-0001'
        self.body={'messages':[{'role':'user','content':'neutral'}],'stream':True}
    async def asyncTearDown(self):
        await self.pool.close();await self.client.aclose()
        self.assertEqual(self.active,0)
    async def first(self):
        await self.pool.submit(self.name,self.body)
        for _ in range(100):
            if self.pool.jobs[self.name].events:return
            await asyncio.sleep(.001)
        self.fail('producer did not start')
    async def test_disconnect_does_not_cancel_and_cursor_replays_once(self):
        await self.first()
        subscriber=self.pool.stream(self.name,0).body_iterator
        first=await anext(subscriber);self.assertIn(b'hello',first)
        await subscriber.aclose()
        self.assertEqual(self.pool.jobs[self.name].state,'generating')
        self.release.set();await self.pool.jobs[self.name].task
        data=json.loads(self.pool.snapshot(self.name,1).body)
        self.assertEqual(data['state'],'completed');self.assertEqual(data['next_cursor'],3)
        self.assertNotIn('hello',''.join(data['events']));self.assertIn('世界',''.join(data['events']))
        self.assertEqual(data['events'][-1],'[DONE]')
    async def test_duplicate_and_conflicting_id(self):
        await self.first()
        self.assertEqual((await self.pool.submit(self.name,self.body)).status_code,202)
        self.assertEqual((await self.pool.submit(self.name,{'messages':[]})).status_code,409)
        self.assertEqual(self.calls,1)
    async def test_cancel_active_and_before_start(self):
        await self.first();await self.pool.cancel(self.name)
        self.assertEqual(self.pool.jobs[self.name].state,'cancelled')
        other='synthetic-request-0002'
        await self.pool.submit(other,self.body);await self.pool.cancel(other)
        self.assertEqual(self.pool.jobs[other].state,'cancelled')
    async def test_incomplete_is_error_not_completed(self):
        self.incomplete=True;await self.first();self.release.set();await self.pool.jobs[self.name].task
        self.assertEqual(self.pool.jobs[self.name].state,'error')
    async def test_capacity_and_expiration_and_bad_cursor(self):
        await self.first()
        await self.pool.submit('synthetic-request-0002',self.body)
        self.assertEqual((await self.pool.submit('synthetic-request-0003',self.body)).status_code,429)
        self.assertEqual(self.pool.snapshot(self.name,9999).status_code,400)
        await self.pool.cancel(self.name)
        self.pool.jobs[self.name].finished-=601
        self.assertEqual(self.pool.snapshot(self.name,0).status_code,404)
    async def test_byte_limit_stops_producer(self):
        self.pool.per_job_bytes=10
        await self.pool.submit(self.name,self.body);await self.pool.jobs[self.name].task
        self.assertEqual(self.pool.jobs[self.name].state,'error')
    async def test_snapshot_pagination_preserves_every_event(self):
        await self.first()
        job=self.pool.jobs[self.name]
        for index in range(600):self.pool.append(job,json.dumps({'index':index}))
        self.release.set();await job.task
        cursor=0;events=[]
        while True:
            page=json.loads(self.pool.snapshot(self.name,cursor).body)
            self.assertLessEqual(len(page['events']),256)
            events.extend(page['events']);cursor=page['next_cursor']
            if not page['has_more']:break
        self.assertEqual(events,job.events)
        self.assertEqual(cursor,len(job.events))
    async def test_completed_eviction_does_not_regenerate_retired_id(self):
        await self.first();self.release.set();await self.pool.jobs[self.name].task
        second='synthetic-request-0002';third='synthetic-request-0003'
        await self.pool.submit(second,self.body);await self.pool.jobs[second].task
        self.assertEqual((await self.pool.submit(third,self.body)).status_code,202)
        self.assertEqual(self.pool.snapshot(self.name,0).status_code,404)
        self.assertEqual((await self.pool.submit(self.name,self.body)).status_code,410)
        self.assertIn(third,self.pool.jobs)


class ContextTests(unittest.IsolatedAsyncioTestCase):
    async def test_normal_budget_unchanged_and_impossible_input_rejected(self):
        def handler(req):
            if req.url.path=='/props':return httpx.Response(200,json={'default_generation_settings':{'n_ctx':4096}})
            data=json.loads(req.content)
            if req.url.path=='/apply-template':return httpx.Response(200,json={'prompt':json.dumps(data['messages'])})
            messages=json.loads(data['content'])
            return httpx.Response(200,json={'tokens':list(range(sum(m['size'] for m in messages)))})
        body={'max_tokens':2048,'messages':[{'role':'system','content':'keep','size':100},
              {'role':'user','content':'current','size':200}]}
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result,stats=await fit_context(body,client,'http://test','test')
            self.assertEqual(result,body);self.assertEqual(stats['removed_messages'],0)
            body['messages'][0]['size']=4096
            with self.assertRaises(ContextOverflow):await fit_context(body,client,'http://test','test')
            self.assertEqual(body['messages'][0]['content'],'keep')
    async def test_preserves_source_system_and_latest_turn(self):
        def handler(req):
            if req.url.path=='/props':return httpx.Response(200,json={'default_generation_settings':{'n_ctx':1000}})
            data=json.loads(req.content)
            if req.url.path=='/apply-template':return httpx.Response(200,json={'prompt':json.dumps(data['messages'])})
            messages=json.loads(data['content'])
            return httpx.Response(200,json={'tokens':list(range(sum(m['size'] for m in messages)))})
        body={'max_tokens':300,'messages':[{'role':'system','content':'keep','size':100},
              {'role':'user','content':'old','size':400},{'role':'assistant','content':'old answer','size':300},
              {'role':'user','content':'current','size':200}]}
        original=json.dumps(body)
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result,stats=await fit_context(body,client,'http://test','test')
        self.assertEqual(json.dumps(body),original)
        self.assertEqual([x['content'] for x in result['messages']],['keep','current'])
        self.assertEqual(result['max_tokens'],300)
        self.assertEqual(stats['removed_messages'],2)


class RouteTests(unittest.IsolatedAsyncioTestCase):
    async def test_auth_and_recoverable_submission(self):
        os.environ.update(SERMO_BACKEND='http://backend',SERMO_API_KEY='synthetic-secret',
                          SERMO_MODEL_FAMILY='scarlet',SERMO_IDLE_MINUTES='60',SERMO_CONTEXT_GUARD='0')
        import proxy
        release=asyncio.Event()
        async def upstream(req):
            return httpx.Response(200,headers={'content-type':'text/event-stream'},stream=Stream(release))
        client=httpx.AsyncClient(transport=httpx.MockTransport(upstream))
        proxy.app.state.client=client
        proxy.app.state.recovery=Recovery(client,'http://backend','synthetic-secret',lambda:None,lambda:None)
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=proxy.app),base_url='http://proxy') as phone:
                url='/v1/requests/neutral-request-0001'
                self.assertEqual((await phone.get(url)).status_code,401)
                headers={'Authorization':'Bearer synthetic-secret'}
                body={'messages':[{'role':'user','content':'neutral'}],'model':'test','stream':True}
                self.assertEqual((await phone.post(url,headers=headers,json=body)).status_code,202)
                self.assertEqual((await phone.get(url,headers={'Authorization':'Bearer wrong'})).status_code,401)
                self.assertEqual((await phone.post(url,headers=headers,json=body)).status_code,202)
                release.set();await proxy.app.state.recovery.jobs['neutral-request-0001'].task
                result=(await phone.get(url,headers=headers)).json()
                self.assertEqual(result['state'],'completed')
                self.assertEqual(result['events'][-1],'[DONE]')
                self.assertEqual((await phone.delete(url,headers=headers)).status_code,200)
        finally:
            await proxy.app.state.recovery.close();await client.aclose()


if __name__=='__main__':unittest.main()
