"""Count using the live backend template/tokenizer; trim only request copies."""
import copy

class ContextOverflow(ValueError):
    pass

async def fit_context(body, client, backend, key):
    result = copy.deepcopy(body)
    headers = {'Authorization':'Bearer '+key}
    props = await client.get(backend+'/props',headers=headers)
    props.raise_for_status()
    context = int(props.json()['default_generation_settings']['n_ctx'])
    wanted = int(result.get('max_tokens', -1))
    reserve = min(wanted, context-64) if wanted > 0 else 0
    if wanted <= 0: wanted = context
    async def count():
        template_body = {k:result[k] for k in ('messages','tools','chat_template_kwargs') if k in result}
        rendered = await client.post(backend+'/apply-template',headers=headers,json=template_body)
        rendered.raise_for_status()
        tokenized = await client.post(backend+'/tokenize',headers=headers,json={
            'content':rendered.json()['prompt'],'add_special':True,'parse_special':True})
        tokenized.raise_for_status()
        return len(tokenized.json()['tokens'])
    messages = result.get('messages')
    if not isinstance(messages,list) or not messages: raise ValueError('messages_required')
    size = await count()
    removed = 0
    while size+reserve+64 > context:
        users = [i for i,m in enumerate(messages) if m.get('role')=='user']
        if len(users)<2: break
        # Remove an entire oldest turn including its tool replies, preserving all system instructions.
        until = users[1]
        old_length = len(messages)
        messages[:] = [m for i,m in enumerate(messages) if i>=until or m.get('role') in ('system','developer')]
        removed += old_length-len(messages)
        size = await count()
    available = context-size-64
    if available < 1: raise ContextOverflow('instructions_and_current_turn_exceed_context')
    result['max_tokens'] = min(wanted,available)
    return result, {'context':context,'input_tokens':size,'removed_messages':removed,
                    'output_budget':result['max_tokens']}
