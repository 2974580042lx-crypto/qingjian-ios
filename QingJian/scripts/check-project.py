#!/usr/bin/env python3
"""Check source references and resources without pretending to compile Swift."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project = (root / "QingJian.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
swift_files = list((root / "DeepSeekPocket").rglob("*.swift"))
assert swift_files, "No Swift sources"
for file in swift_files:
    relative = file.relative_to(root).as_posix()
    assert f'path = "{relative}";' in project, f"Missing source reference: {relative}"
    text = file.read_text(encoding="utf-8")
    assert not re.search(r'\bsk-[A-Za-z0-9]{12,}', text), f"Possible embedded API key: {relative}"
plist = plistlib.loads((root / "DeepSeekPocket/Info.plist").read_bytes())
assert plist["CFBundleDisplayName"] == "Sermo"
assert "NSAppTransportSecurity" not in plist, "Do not weaken HTTPS transport requirements"
scheme = ET.parse(root / "QingJian.xcodeproj/xcshareddata/xcschemes/QingJian.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] in project
for contents in (root / "DeepSeekPocket/Assets.xcassets").rglob("Contents.json"):
    metadata = json.loads(contents.read_text())
    for image in metadata.get("images", []):
        if "filename" in image:
            assert (contents.parent / image["filename"]).is_file(), "Missing icon image"
for artifact in root.rglob("*"):
    assert artifact.suffix not in {".p12", ".mobileprovision", ".cer", ".pem"}, "Signing secrets must stay outside this project"
print(f"Project structure OK: {len(swift_files)} Swift files, Info.plist, scheme and resources.")
print("This check does not replace an Xcode build or a real-device test.")
