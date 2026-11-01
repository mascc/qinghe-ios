#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/ios/PornShopPlayer.xcodeproj"
DERIVED="$ROOT/build/ios"
APP="$DERIVED/Build/Products/Release-iphoneos/PornShopPlayer.app"
OUTPUT="$ROOT/release"
STAGING="$DERIVED/unsigned-ipa"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS 构建需要 macOS 和 Xcode。" >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme PornShopPlayer \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP" ]]; then
  echo "未生成 iOS 应用：$APP" >&2
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING/Payload" "$OUTPUT"
ditto "$APP" "$STAGING/Payload/PornShopPlayer.app"
IPA="$OUTPUT/青禾学堂-1.9.4-ios-unsigned.ipa"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Payload" "$IPA"
shasum -a 256 "$IPA" > "$OUTPUT/SHA256SUMS.txt"
echo "OK $IPA"
