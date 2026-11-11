#!/usr/bin/env python3
"""Convert a user-owned reading JSON to a private Sermo pack and auditable Markdown.

No documents are downloaded. Source files are read-only. Optional annotations
contain reviewed topics, exact replacements, and source labels; no model fills gaps.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

BASIC_WORDS = set("""a an the and or but if while when where who whom whose which what why how
as at by for from in into of on onto out over under to up upon with without about after
before between through during against among across within than then so that this these those
i me my mine myself we us our ours ourselves you your yours yourself yourselves he him his
himself she her hers herself it its itself they them their theirs themselves all any both
each either every few many much more most other some such no nor not only own same too very
am is are was were be been being have has had having do does did doing will would shall
should can could may might must ought need dare here there now just also even still already
again ever never often always sometimes once twice well less least one two three four five
six seven eight nine ten first second third next last new old good better best bad worse worst
big small long short little large high low right left made make makes get gets got go goes
went come comes came take takes took give gives gave see sees saw say says said know knows
knew think thinks thought want wants wanted like likes people person time year years day days
thing things way ways let lets use uses used using been don't doesn't didn't isn't aren't
wasn't weren't haven't hasn't hadn't won't wouldn't can't couldn't shouldn't it's that's
there's they're we're you're i've we've you've i'd we'd you'd i'll we'll you'll he's she's
because though although since until yet whether along away back off per another around
everything nothing something anything anyone everyone someone nobody enough together really
yes oh well else somewhere anywhere everywhere nowhere almost quite rather perhaps indeed
""".split())
TOKEN = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*", re.UNICODE)

def words(text):
    return [m.group(0).lower().replace('’', "'") for m in TOKEN.finditer(text)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--annotations', type=Path)
    args = parser.parse_args()
    original = args.input.read_bytes()
    source = json.loads(original)
    passages = source.get('readings', source.get('passages', []))
    assert passages and len({p['id'] for p in passages}) == len(passages)
    annotations = json.loads(args.annotations.read_text(encoding='utf-8')) if args.annotations else {}
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    pack, audit, index, occurrences = [], [], [], defaultdict(Counter)
    pending = []
    for p in sorted(passages, key=lambda p: (p['year'], p['textNumber'])):
        entry = {k: p[k] for k in ['id', 'title', 'year', 'textNumber', 'paragraphs', 'questions', 'source', 'sourceURL'] if k in p}
        entry = json.loads(json.dumps(entry, ensure_ascii=False))
        note = annotations.get(p['id'], {})
        entry['topic'] = note.get('topic')
        for change in note.get('replacements', []):
            at = change['paragraph'] - 1
            old = entry['paragraphs'][at]
            assert old.count(change['from']) == 1, change
            entry['paragraphs'][at] = old.replace(change['from'], change['to'])
            audit.append({'passage': p['id'], **change})
        if 'source' in note:
            entry['source'] = note['source']
            entry['sourceURL'] = note.get('sourceURL')
        assert 1 <= len(entry['paragraphs']) <= 40
        assert all(s.strip() and '\ufffd' not in s for s in entry['paragraphs'])
        assert len(entry['questions']) == 5, p['id']
        expected_numbers = list(range(21 + 5 * (p['textNumber'] - 1), 26 + 5 * (p['textNumber'] - 1)))
        assert [q['number'] for q in entry['questions']] == expected_numbers
        for q in entry['questions']:
            assert len(q['options']) == 4 and all(q['options']) and q['stem']
            assert q.get('answer') is None or 0 <= q['answer'] <= 3
            if q['verification'] != 'verified':
                pending.append({'passage': p['id'], 'question': q['number'], 'status': q['verification']})
                # Keep the conflicting candidate only in the source file. The app
                # must not receive a candidate labelled as a usable answer.
                q['answer'] = None
        tokens = words('\n'.join(entry['paragraphs']))
        location = f"{p['year']} Text {p['textNumber']}"
        for token, count in Counter(tokens).items():
            if len(token) > 1 and token not in BASIC_WORDS:
                occurrences[token][location] += count
        relative = f"{p['year']}/阅读Text{p['textNumber']}.md"
        target = output / relative
        target.parent.mkdir(exist_ok=True)
        body = [f"# {p['title']}", '', '来源：' + entry['source'], '', '## 原文', '']
        for number, paragraph in enumerate(entry['paragraphs'], 1):
            body += [f'### 第 {number} 段', '', paragraph, '']
        body += ['## 题目和选项', '']
        for q in entry['questions']:
            body += [f"### {q['number']}. {q['stem']}", '']
            body += [f"{chr(65+i)}. {text}" for i, text in enumerate(q['options'])] + ['']
        body += ['## 答案', '', '以下为跨源参考答案，并非官方答案；待核题不提供候选答案。', '']
        for q in entry['questions']:
            answer = chr(65 + q['answer']) if q['verification'] == 'verified' and q['answer'] is not None else '待核'
            body += [f"- {q['number']}：{answer}。来源：{q['source']}。{q.get('explanation','')}"]
        target.write_text('\n'.join(body) + '\n', encoding='utf-8')
        index.append(f"| [{location}]({relative}) | {entry['topic'] or '主题未标注'} | {len(tokens)} | {len(entry['paragraphs'])} | {','.join(str(q['number']) for q in entry['questions'] if q['verification'] != 'verified') or '无'} |")
        pack.append(entry)
    (output/'Sermo阅读导入包.json').write_text(json.dumps({'schema':'sermo.readings.v1','passages':pack},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (output/'index.md').write_text('# 英语一阅读索引\n\n只包含实际找到的阅读A。主题为整理标签，非原卷标题。字数仅统计原文英文词形，不包含题目和答案。\n\n| 年份篇目 | 主题 | 字数 | 段数 | 答案待核题号 |\n|---|---|---:|---:|---|\n'+'\n'.join(index)+'\n',encoding='utf-8')
    for year in sorted({p['year'] for p in pack}):
        (output/str(year)/'缺失说明.md').write_text('# 本包未收录\n\n新题型、完形、翻译、写作：本包缺失，不编造补齐。另有未定本的研究原始资料，未自动混入本次导入包。\n',encoding='utf-8')
    freq = ['# 真题词频表', '', '只统计导入包的阅读原文。小写合并，直/弯撇号统一；不做词形还原，复数、过去式各自统计。每个位置标实际出现次数。',
            '基础词按配套的自定义排除清单去除，另去除单字母词；该清单不是英语等级测评结果，可按需要调整脚本。频次是这份资料中的频次，不代表考试词频或个人掌握程度。', '', '| 词形 | 出现次数 | 出处及次数 |', '|---|---:|---|']
    for word, locations in sorted(occurrences.items(), key=lambda pair: (-sum(pair[1].values()), pair[0])):
        freq.append(f"| {word} | {sum(locations.values())} | "+'；'.join(f'{k}×{v}' for k,v in sorted(locations.items()))+' |')
    (output/'真题词频表.md').write_text('\n'.join(freq)+'\n',encoding='utf-8')
    (output/'基础词排除清单.txt').write_text('\n'.join(sorted(BASIC_WORDS))+'\n',encoding='utf-8')
    report = {'source_sha256':hashlib.sha256(original).hexdigest(), 'passages':len(pack),'questions':sum(len(p['questions']) for p in pack),
              'pending_answers':pending,'exact_replacements':audit,'word_forms_after_filter':len(occurrences),
              'counts_include_only_paragraphs':True,'source_preserved':args.input.read_bytes()==original}
    (output/'转换核对.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ['exact_replacements','pending_answers']},ensure_ascii=True))

if __name__ == '__main__':
    main()
