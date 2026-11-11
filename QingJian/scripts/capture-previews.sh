#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
mkdir -p "$BUILD_DIR/previews"
cd "$PROJECT_ROOT"
xcrun simctl list devices available -j > "$BUILD_DIR/previews/devices.json"
UDID="$(python3 - "$BUILD_DIR/previews/devices.json" <<'PY'
import json,sys,re
data=json.load(open(sys.argv[1]))['devices']
for runtime,devices in sorted(data.items(),reverse=True):
    match=re.search(r'iOS-(\d+)',runtime)
    if not match or int(match.group(1))<26:continue
    phones=[d for d in devices if d.get('isAvailable') and d['name'].startswith('iPhone')]
    phones.sort(key=lambda d:(d['name']!='iPhone 17 Pro',d['name']!='iPhone 16 Pro',d['name']))
    if phones:
        print(phones[0]['udid'])
        break
else:raise SystemExit('No iOS 26+ simulator available')
PY
)"
# Compile the UI test target before booting and capturing previews, so test
# source errors fail early. The complete UI suite still executes below.
xcodebuild -project QingJian.xcodeproj -scheme QingJian -configuration Release \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$BUILD_DIR/SimulatorDerivedData" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build-for-testing
APP_PATH="$BUILD_DIR/SimulatorDerivedData/Build/Products/Release-iphonesimulator/DeepSeekPocket.app"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl status_bar "$UDID" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" "$APP_PATH"

COMPILED_ICON="$APP_PATH/AppIcon60x60@2x.png"
if [[ -f "$COMPILED_ICON" ]]; then
  sips -s format png "$COMPILED_ICON" --out "$BUILD_DIR/previews/compiled-app-icon.png" >/dev/null
fi
python3 - "$APP_PATH/Info.plist" "$BUILD_DIR/previews/branding.json" "$PROJECT_ROOT/scripts/generate-project.py" <<'PY'
import plistlib,json,sys,re
with open(sys.argv[1],'rb') as f: p=plistlib.load(f)
# The expected version comes from the project generator, the one place it is set,
# so a version bump can no longer leave a stale number behind here.
source=open(sys.argv[3],encoding='utf-8').read()
version=re.search(r'"MARKETING_VERSION": "([^"]+)"',source).group(1)
build=re.search(r'"CURRENT_PROJECT_VERSION": "([^"]+)"',source).group(1)
assert p['CFBundleDisplayName']=='Sermo'
assert p['CFBundleIdentifier']=='com.xiaolong.qingjian'
assert p['CFBundleShortVersionString']==version, (p['CFBundleShortVersionString'], version)
assert p['CFBundleVersion']==build, (p['CFBundleVersion'], build)
with open(sys.argv[2],'w') as f: json.dump({k:p[k] for k in ('CFBundleDisplayName','CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion')},f,indent=2)
print('VOX_BRANDING_VERIFIED=true')
PY

xcrun simctl ui "$UDID" appearance light
for screen in empty sidebar settings reply-suggestions projects project all-chats; do
  args=(--ui-preview "--preview-$screen")
  xcrun simctl launch --terminate-running-process --stdout="$BUILD_DIR/previews/light-$screen.log" \
    "$UDID" com.xiaolong.qingjian "${args[@]}" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
  sleep 3
  xcrun simctl io "$UDID" screenshot "$BUILD_DIR/previews/light-$screen.png"
done

xcrun simctl ui "$UDID" appearance dark
for screen in empty conversation long keyboard sidebar waiting thinking reasoning-translated reply-suggestions usage project; do
  args=(--ui-preview)
  if [[ "$screen" != conversation ]]; then args+=("--preview-$screen"); fi
  xcrun simctl launch --terminate-running-process --stdout="$BUILD_DIR/previews/$screen.log" \
    "$UDID" com.xiaolong.qingjian "${args[@]}" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
  sleep 3
  xcrun simctl io "$UDID" screenshot "$BUILD_DIR/previews/$screen.png"
done
# The Swiss look, in light and dark, from the same preview data.
for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for screen in conversation empty reply-suggestions sidebar settings; do
    args=(--ui-preview --preview-swiss)
    if [[ "$screen" != conversation ]]; then args+=("--preview-$screen"); fi
    xcrun simctl launch --terminate-running-process --stdout="$BUILD_DIR/previews/swiss-$appearance-$screen.log" \
      "$UDID" com.xiaolong.qingjian "${args[@]}" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
    sleep 3
    xcrun simctl io "$UDID" screenshot "$BUILD_DIR/previews/swiss-$appearance-$screen.png"
  done
done
echo "UI previews captured from the actual simulator app."
set +e
xcodebuild -project QingJian.xcodeproj -scheme QingJian -configuration Release \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$BUILD_DIR/SimulatorDerivedData" -resultBundlePath "$BUILD_DIR/UIInteractionTests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
UI_TEST_STATUS=$?
set -e
xcrun xcresulttool export attachments --path "$BUILD_DIR/UIInteractionTests.xcresult" \
  --output-path "$BUILD_DIR/previews/interaction-tests" || true
xcrun xcresulttool get test-results summary --path "$BUILD_DIR/UIInteractionTests.xcresult" \
  > "$BUILD_DIR/previews/interaction-tests-summary.json" || true
exit "$UI_TEST_STATUS"
