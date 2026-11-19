#!/usr/bin/env bash
# Build ARIFA's release APK. Works on PC and on aarch64 Termux.
set -euo pipefail
cd "$(dirname "$0")/.."

# Never ship Flutter's default launcher icons.
python3 scripts/generate_icon.py

flutter pub get

if [ -n "${PREFIX:-}" ]; then
  echo "Termux/aarch64 build..."
  flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons
else
  echo "Desktop build..."
  flutter build apk --release
fi

APK="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK" ]; then
  echo "APK ready: $PWD/$APK"
  ls -lh "$APK"
else
  echo "Build finished but APK not found at $APK" >&2
  exit 1
fi
