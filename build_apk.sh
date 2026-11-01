#!/usr/bin/env bash
# 在本目录打出可旁加载的 release APK。
# 需要 JDK 17+，以及带 Android 34 平台的 SDK。优先使用 ANDROID_HOME。
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/platforms" ]]; then
  SDK_DIR="$ANDROID_HOME"
elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/platforms" ]]; then
  SDK_DIR="$ANDROID_SDK_ROOT"
elif [[ -d "$ANDROID_DIR/../../pektino/android-sdk/platforms" ]]; then
  SDK_DIR="$(cd "$ANDROID_DIR/../../pektino/android-sdk" && pwd)"
elif [[ -d "$ANDROID_DIR/../pektino/android-sdk/platforms" ]]; then
  SDK_DIR="$(cd "$ANDROID_DIR/../pektino/android-sdk" && pwd)"
else
  echo "找不到 Android SDK。请安装 compileSdk 34，并设置 ANDROID_HOME。" >&2
  exit 1
fi

jdk_ok=0
if [[ -n "${JAVA_HOME:-}" ]]; then
  if [[ -x "$JAVA_HOME/bin/keytool" || -x "$JAVA_HOME/bin/keytool.exe" ]]; then
    jdk_ok=1
  fi
fi
if [[ "$jdk_ok" -ne 1 ]]; then
  if command -v keytool >/dev/null 2>&1; then
    JAVA_BIN="$(command -v keytool)"
    JAVA_HOME="$(cd "$(dirname "$JAVA_BIN")/.." && pwd)"
  else
    echo "找不到 JDK 17+。请设置 JAVA_HOME。" >&2
    exit 1
  fi
fi

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

SDK_PROP="${SDK_DIR//\\//}"
printf 'sdk.dir=%s\n' "$SDK_PROP" > "$ANDROID_DIR/local.properties"
echo "sdk.dir=$SDK_PROP"
echo "JAVA_HOME=$JAVA_HOME"

mkdir -p "$ANDROID_DIR/keystore"
KS="$ANDROID_DIR/keystore/pornshop-release.jks"
if [[ ! -f "$KS" ]]; then
  keytool -genkeypair \
    -keystore "$KS" \
    -alias pornshop \
    -keyalg RSA \
    -keysize 2048 \
    -validity 3650 \
    -storepass pornshop123 \
    -keypass pornshop123 \
    -dname "CN=PornShop Player, OU=SelfUse, O=Local, L=Local, ST=Local, C=CN"
fi

cd "$ANDROID_DIR"
chmod +x ./gradlew || true
./gradlew --no-daemon assembleRelease

APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "APK missing: $APK" >&2
  exit 1
fi
mkdir -p "$ANDROID_DIR/release"
OUT="$ANDROID_DIR/release/青禾学堂-0.2.0.apk"
cp -f "$APK" "$OUT"
echo "OK $OUT"
ls -lh "$APK" "$OUT"
