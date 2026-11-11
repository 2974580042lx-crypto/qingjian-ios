#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
IPA_PATH="$BUILD_DIR/QingJian-unsigned.ipa"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "需要 macOS 和完整 Xcode。Windows/Linux 请使用项目内的 GitHub Actions 工作流。" >&2
  exit 1
fi

cd "$PROJECT_ROOT"
for candidate in /Applications/Xcode_26.3.app /Applications/Xcode_26.2.app /Applications/Xcode_26.1.1.app /Applications/Xcode_26.0.1.app; do
  if [[ -d "$candidate/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$candidate/Contents/Developer"
    break
  fi
done
xcodebuild -version
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt 26 ]]; then
  echo "本版原生液态玻璃需要 iOS 26 或更高 SDK。" >&2
  exit 1
fi
mkdir -p "$BUILD_DIR"
python3 scripts/check-project.py
swift test --jobs 2

xcodebuild \
  -project QingJian.xcodeproj \
  -scheme QingJian \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/DeepSeekPocket.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "构建没有生成预期的 App。" >&2
  exit 1
fi

# This directory is only our generated build output, never user data.
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
ditto "$APP_PATH" "$BUILD_DIR/Payload/DeepSeekPocket.app"
rm -f "$IPA_PATH"
ditto -c -k --keepParent "$BUILD_DIR/Payload" "$IPA_PATH"
echo "已生成未签名 IPA：$IPA_PATH"
echo "请使用你自己的适用证书和描述文件签名后安装。"

if [[ "${QINGJIAN_CAPTURE_PREVIEWS:-0}" == "1" ]]; then
  bash "$PROJECT_ROOT/scripts/capture-previews.sh"
fi
