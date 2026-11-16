"""Authenticated, bounded, memory-only SSE recovery. Routes are guarded by proxy.py."""
import asyncio
from dataclasses import dataclass, field
import hashlib
import json
import re
import time

from fastapi.responses import JSONResponse, StreamingResponse


@dataclass
class Job:
    digest: str
    state: str = 'generating'
    events: list = field(default_factory=list)
    size: int = 0
    updated: float = field(default_factory=time.monotonic)
    finished: float | None = None
    task: asyncio.Task | None = None
    signal: asyncio.Event = field(default_factory=asyncio.Event)
    error: str | None = None


class Recovery:
    def __init__(self, client, backend, key, begin, end, max_jobs=20,
                 max_bytes=32*1024*1024, per_job_bytes=4*1024*1024, ttl=600):
        self.client, self.backend, self.key = client, backend, key
        self.begin, self.end = begin, end
        self.max_jobs, self.max_bytes, self.per_job_bytes, self.ttl = max_jobs, max_bytes, per_job_bytes, ttl
        self.jobs = {}
        self.retired = {}

    def prune(self):
        now = time.monotonic()
        for name, job in list(self.jobs.items()):
            if job.finished is not None and now-job.finished > self.ttl:
                del self.jobs[name]
        self.retired = {name:info for name,info in self.retired.items() if now-info[1] <= self.ttl}

    def evict_completed(self):
        candidates = [(job.finished,name) for name,job in self.jobs.items() if job.finished is not None]
        if not candidates or len(self.retired) >= 200: return False
        _,name = min(candidates)
        old = self.jobs.pop(name)
        # Keep a small bounded tombstone so a retransmitted ID is not re-generated.
        self.retired[name] = (old.digest,time.monotonic())
        old.events.clear()
        old.size = 0
        return True

    @staticmethod
    def valid_id(name):
        return re.fullmatch(r'[A-Za-z0-9_-]{16,80}', name) is not None

    def append(self, job, event):
        size = len(event.encode('utf-8'))
        if job.size+size > self.per_job_bytes:
            raise RuntimeError('buffer_capacity')
        while sum(x.size for x in self.jobs.values())+size > self.max_bytes and self.evict_completed():
            pass
        if job.size+size > self.per_job_bytes or sum(x.size for x in self.jobs.values())+size > self.max_bytes:
            raise RuntimeError('buffer_capacity')
        job.events.append(event)
        job.size += size
        job.updated = time.monotonic()
        job.signal.set()

    async def submit(self, name, body, request_digest=None):
        self.prune()
        if not self.valid_id(name): return JSONResponse({'error':'invalid_request_id'},400)
        content = json.dumps(body, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        digest = request_digest or hashlib.sha256(content).hexdigest()
        if name in self.retired:
            return JSONResponse({'error':'request_expired'},410 if self.retired[name][0]==digest else 409)
        if name in self.jobs:
            if self.jobs[name].digest != digest: return JSONResponse({'error':'request_id_conflict'},409)
            return JSONResponse({'request_id':name,'state':self.jobs[name].state},202)
        # Retain the newest completed requests; active generations are never evicted.
        while (len(self.jobs) >= self.max_jobs or sum(x.size for x in self.jobs.values()) >= self.max_bytes) and self.evict_completed():
            pass
        if len(self.jobs) >= self.max_jobs or sum(x.size for x in self.jobs.values()) >= self.max_bytes:
            return JSONResponse({'error':'recovery_capacity','retry_after':30},429)
        job = Job(digest=digest)
        self.jobs[name] = job
        job.task = asyncio.create_task(self.produce(job, body))
        return JSONResponse({'request_id':name,'state':job.state},202)

    async def produce(self, job, body):
        self.begin()
        done = False
        reason = False
        try:
            async with asyncio.timeout(3600):
                async with self.client.stream('POST', self.backend+'/v1/chat/completions',
                        headers={'Authorization':'Bearer '+self.key,'Accept-Encoding':'identity'},
                        json={**body, 'stream':True}) as response:
                    if response.status_code != 200: raise RuntimeError('upstream_http_'+str(response.status_code))
                    if 'text/event-stream' not in response.headers.get('content-type',''):
                        raise RuntimeError('upstream_format')
                    data = []
                    line_bytes = 0
                    async for line in response.aiter_lines():
                        line_bytes += len(line.encode('utf-8'))
                        if line_bytes > self.per_job_bytes: raise RuntimeError('event_capacity')
                        if line.startswith('data:'): data.append(line[5:].lstrip(' '))
                        if line or not data: continue
                        event = '\n'.join(data)
                        data, line_bytes = [], 0
                        if event.strip() == '[DONE]':
                            done = True
                            self.append(job, '[DONE]')
                            break
                        parsed = json.loads(event)
                        if parsed.get('error'): raise RuntimeError('upstream_stream_error')
                        reason |= any(x.get('finish_reason') is not None for x in parsed.get('choices',[]))
                        self.append(job, event)
                    if not (done and reason): raise RuntimeError('upstream_incomplete')
                    job.state = 'completed'
        except asyncio.CancelledError:
            job.state, job.error = 'cancelled', 'cancelled'
        except Exception as error:
            job.state = 'error'
            # No exception strings: they can contain response bodies or private URLs.
            job.error = type(error).__name__
        finally:
            job.finished = time.monotonic()
            job.signal.set()
            self.end()

    def snapshot(self, name, after):
        self.prune()
        job = self.jobs.get(name)
        if job is None: return JSONResponse({'error':'request_not_found_or_expired'},404)
        if after < 0 or after > len(job.events): return JSONResponse({'error':'invalid_cursor'},400)
        end = min(after+256, len(job.events))
        return JSONResponse({'request_id':name,'state':job.state,'events':job.events[after:end],
                             'next_cursor':end,'has_more':end<len(job.events),'error':job.error})

    async def cancel(self, name):
        self.prune()
        job = self.jobs.get(name)
        if job is None: return JSONResponse({'error':'request_not_found_or_expired'},404)
        if job.state == 'generating' and job.task:
            job.task.cancel()
            await asyncio.gather(job.task, return_exceptions=True)
            if job.state == 'generating':
                job.state, job.error, job.finished = 'cancelled', 'cancelled', time.monotonic()
                job.signal.set()
        return JSONResponse({'state':job.state})

    def stream(self, name, after):
        self.prune()
        job = self.jobs.get(name)
        if job is None: return JSONResponse({'error':'request_not_found_or_expired'},404)
        if after < 0 or after > len(job.events): return JSONResponse({'error':'invalid_cursor'},400)
        async def events():
            cursor = after
            while True:
                while cursor < len(job.events):
                    event = job.events[cursor]
                    cursor += 1
                    yield ('id: '+str(cursor)+'\n'+''.join('data: '+line+'\n' for line in event.split('\n'))+'\n').encode()
                if job.state != 'generating':
                    return
                job.signal.clear()
                try: await asyncio.wait_for(job.signal.wait(),10)
                except TimeoutError: yield b': ping\n\n'
        return StreamingResponse(events(),media_type='text/event-stream',
                                 headers={'Cache-Control':'no-store','X-Accel-Buffering':'no'})

    async def close(self):
        tasks = [x.task for x in self.jobs.values() if x.task and not x.task.done()]
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.jobs.clear()
        self.retired.clear()
