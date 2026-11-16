"""Optional one-setting trial; normal startup files and model/context remain unchanged.

Upload only when the user is ready for a brief same-VM service restart.
Rollback: start the normal workbench_run.py again.
"""
from pathlib import Path

def _eos_trial_proxy(source):
    start=source.index('def format_scarlet(body):')
    end=source.index('\n\n@app.api_route',start)
    section=source[start:end]
    if section.count('    return body')!=1:
        raise RuntimeError('Scarlet proxy structure changed; trial refused')
    addition=('    # Mild bias only: EOS remains available; do not enable ignore_eos.\n'
              '    body.setdefault("logit_bias", {"248046": -1.0, "248044": -1.0})\n'
              '    return body')
    section=section.replace('    return body',addition)
    patched=source[:start]+section+source[end:]
    compile(patched,'sermo_proxy_eos_trial','exec')
    return patched

_normal=(Path('/content/sermo_colab')/'workbench_run.py').read_text(encoding='utf-8')
_anchor='scope["launch"]()'
if _normal.count(_anchor)!=1:
    raise RuntimeError('Workbench structure changed; trial refused')
_trial=_normal.replace(_anchor,
    'scope["PROXY_SOURCE"] = _eos_trial_proxy(scope["PROXY_SOURCE"])\n'+_anchor)
print('Scarlet experimental EOS bias -1.0; normal ending remains enabled.',flush=True)
exec(compile(_trial,'workbench_run_eos_trial','exec'))
