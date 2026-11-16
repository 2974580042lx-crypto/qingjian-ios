"""Neutral Scarlet comparisons. Default is offline; never allocates a GPU.

--execute requires an already-running endpoint and an explicitly supplied existing
client output budget. It does not change server defaults or phone settings.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import time

ROOT = Path(__file__).resolve().parent


def repeat_indicators(text):
    # Indicators only: quotes and requested repetition can be entirely legitimate.
    paragraphs = [x.strip() for x in re.split(r'\n\s*\n', text) if len(x.strip()) >= 30]
    counts = Counter(paragraphs)
    duplicate_chars = sum(len(x) * (n - 1) for x, n in counts.items() if n > 1)
    return {'characters': len(text), 'duplicate_paragraph_characters': duplicate_chars,
            'duplicate_paragraph_ratio': round(duplicate_chars / max(1, len(text)), 4),
            'needs_human_review': True}


def make_body(plan, profile, case, model, seed, output_budget):
    settings = {k: v for k, v in profile.items() if k != 'name'}
    return {**plan['shared_test_settings'], **settings, 'model': model,
            'messages': case['messages'], 'seed': seed, 'stream': True,
            'stream_options': {'include_usage': True}, 'max_tokens': output_budget,
            'chat_template_kwargs': {'enable_thinking': False}}


def collect(endpoint, body, deadline):
    import requests
    started = time.monotonic()
    result = {'done': False, 'finish_reasons': [], 'text': '', 'reasoning_characters': 0,
              'submitted_parameters': {k: v for k, v in body.items() if k not in ('messages', 'model')},
              'semantic_complete': None, 'appropriate_length': None,
              'unwanted_repetition': None, 'language_or_name_damage': None}
    try:
        with requests.post(endpoint['base_url'].rstrip('/') + '/chat/completions',
                           headers={'Authorization': 'Bearer ' + endpoint['api_key']},
                           json=body, stream=True, timeout=(15, 30)) as response:
            result['http_status'] = response.status_code
            response.raise_for_status()
            if 'text/event-stream' not in response.headers.get('content-type', ''):
                raise ValueError('Expected SSE')
            data_lines = []
            for line in response.iter_lines(chunk_size=1):
                if time.monotonic() >= deadline:
                    result['censored'] = 'experiment_wall_budget'
                    break
                if line.startswith(b'data:'):
                    data_lines.append(line[5:].lstrip(b' '))
                if line or not data_lines:
                    continue
                data = b'\n'.join(data_lines)
                data_lines.clear()
                if data.strip() == b'[DONE]':
                    result['done'] = True
                    break
                event = json.loads(data)
                if event.get('error'):
                    result['server_error'] = True
                    break
                for key in ('usage', 'timings'):
                    if event.get(key): result[key] = event[key]
                for choice in event.get('choices', []):
                    delta = choice.get('delta', {})
                    piece = delta.get('content') or ''
                    if piece and 'first_content_seconds' not in result:
                        result['first_content_seconds'] = round(time.monotonic() - started, 3)
                    result['text'] += piece
                    result['reasoning_characters'] += len(delta.get('reasoning_content') or '')
                    if choice.get('finish_reason'):
                        result['finish_reasons'].append(choice['finish_reason'])
    except Exception as error:
        # URLs in exception strings may contain service details; don't print them.
        result['error_type'] = type(error).__name__
    result['seconds'] = round(time.monotonic() - started, 3)
    result.update(repeat_indicators(result['text']))
    if 'length' in result['finish_reasons']: result['censored'] = 'existing_output_budget'
    result['protocol_complete'] = bool(result['done'] and 'stop' in result['finish_reasons']
                                       and not result.get('censored') and not result.get('server_error')
                                       and not result.get('error_type'))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--endpoint', type=Path)
    parser.add_argument('--client-output-budget', type=int)
    parser.add_argument('--minutes', type=float, default=15)
    parser.add_argument('--request-minutes', type=float, default=3)
    parser.add_argument('--profiles', nargs='+', default=['A_current_control', 'B_author_baseline_no_eos_bias'])
    parser.add_argument('--cases', nargs='+')
    parser.add_argument('--seeds', nargs='+', type=int, default=[17, 53, 101])
    args = parser.parse_args()
    plan = json.loads((ROOT / 'experiment-plan.json').read_text(encoding='utf-8'))
    cases = json.loads((ROOT / 'neutral-cases.json').read_text(encoding='utf-8'))
    profiles = {p['name']: p for p in plan['profiles']}
    if any(p not in profiles for p in args.profiles): parser.error('Unknown profile')
    if args.cases:
        if set(args.cases) - {c['id'] for c in cases}: parser.error('Unknown case')
        cases = [c for c in cases if c['id'] in args.cases]
    # Counterbalance order instead of always warming the shared slot with A first.
    jobs = []
    for case in cases:
        for seed_index, seed in enumerate(args.seeds):
            order = args.profiles if seed_index % 2 == 0 else list(reversed(args.profiles))
            jobs.extend((case, seed, profiles[name]) for name in order)
    if not args.execute:
        print(json.dumps({'offline': True, 'requests_planned': len(jobs), 'profiles': args.profiles,
                          'cases': [c['id'] for c in cases], 'network_requests': 0}))
        return
    if not args.endpoint or not args.client_output_budget or args.client_output_budget < 1:
        parser.error('Execution requires endpoint and the existing client output budget')
    if not 0 < args.minutes <= 60: parser.error('Experiment duration must be in (0, 60] minutes')
    if not 0 < args.request_minutes <= args.minutes: parser.error('Invalid per-request experiment time budget')
    endpoint = json.loads(args.endpoint.read_text(encoding='utf-8'))
    deadline = time.monotonic() + args.minutes * 60
    folder = ROOT / 'results' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    folder.mkdir(parents=True)
    for index, (case, seed, profile) in enumerate(jobs):
        if time.monotonic() >= deadline: break
        body = make_body(plan, profile, case, endpoint['model'], seed, args.client_output_budget)
        result = collect(endpoint, body, min(deadline, time.monotonic()+args.request_minutes*60))
        result.update({'case': case['id'], 'profile': profile['name'], 'seed': seed, 'judge': case['judge']})
        (folder / f'{index:03d}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({k: result.get(k) for k in ['case', 'profile', 'seed', 'characters',
                         'finish_reasons', 'protocol_complete', 'censored', 'error_type']}), flush=True)
        if result.get('error_type') or result.get('server_error'): break


if __name__ == '__main__':
    main()
