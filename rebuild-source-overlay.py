"""Rebuild the cumulative overlay from the verified 1.12 source and current source tree."""
import hashlib
import json
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent
source = root / 'QingJian'
baseline = root / 'QingJian-iOS-source.zip'
expected_hash = 'cb5332b71990c74ff38670cbb7d6213d55b49ecafa6255cd75869f573b2ff460'
assert hashlib.sha256(baseline.read_bytes()).hexdigest() == expected_hash
assert source.is_dir()
current = {p.relative_to(root).as_posix(): p.read_bytes() for p in source.rglob('*') if p.is_file()}
with zipfile.ZipFile(baseline) as archive:
    original = {item.filename: archive.read(item) for item in archive.infolist() if not item.is_dir()}
assert all(name.startswith('QingJian/') and '..' not in Path(name).parts for name in original)
assert all(name.startswith('QingJian/') and '..' not in Path(name).parts for name in current)
overlay = {name: data for name, data in current.items() if original.get(name) != data}
deletions = sorted(set(original) - set(current))
with zipfile.ZipFile(root / 'source-overlay.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for name, data in sorted(overlay.items()):
        item = zipfile.ZipInfo(name, (2026, 10, 29, 0, 0, 0))
        item.compress_type = zipfile.ZIP_DEFLATED
        item.external_attr = (0o100644 << 16)
        archive.writestr(item, data)
manifest = {name: hashlib.sha256(data).hexdigest() for name, data in sorted(current.items())}
(root / 'source-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
(root / 'source-deletions.json').write_text(json.dumps(deletions, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'{len(current)} files, {len(overlay)} cumulative overlay files, {len(deletions)} deletions')
