"""Reconstruct and verify the exact user-supplied source tree before building."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

ROOT = Path.cwd()
EXPECTED_BASELINE = 'cb5332b71990c74ff38670cbb7d6213d55b49ecafa6255cd75869f573b2ff460'

def safe_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'QingJian':
        raise ValueError(f'Unexpected source path: {name}')
    return ROOT.joinpath(*path.parts)

def extract(archive):
    with zipfile.ZipFile(archive) as z:
        for entry in z.infolist():
            target = safe_path(entry.filename)
            if ((entry.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError(f'Symlink rejected: {entry.filename}')
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(entry))
                mode = (entry.external_attr >> 16) & 0o777
                if mode:
                    target.chmod(mode)

archive = ROOT / 'QingJian-iOS-source.zip'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == EXPECTED_BASELINE, 'Baseline ZIP mismatch'
assert not (ROOT / 'QingJian').exists(), 'Source directory must be absent before reconstruction'
extract(archive)
for name in json.loads((ROOT / 'source-deletions.json').read_text()):
    safe_path(name).unlink()
extract(ROOT / 'source-overlay.zip')
expected = json.loads((ROOT / 'source-manifest.json').read_text())
actual = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in (ROOT / 'QingJian').rglob('*') if p.is_file()}
assert actual == expected, f'Source manifest mismatch: missing={expected.keys()-actual.keys()}, extra={actual.keys()-expected.keys()}, changed={[k for k in expected.keys() & actual.keys() if expected[k] != actual[k]]}'
print(f'Verified reconstructed source contents: {len(actual)} files, Sermo 1.18.0 build 42.')
