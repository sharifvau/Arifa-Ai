#!/usr/bin/env bash
# Build ARIFA's release APK. Works on PC and on aarch64 Termux.
set -euo pipefail
cd "$(dirname "$0")/.."

# Fresh clones lack Flutter-generated wrapper scripts/JAR and styles.xml.
# Regenerate the Android scaffold deterministically before invoking Gradle.
if [ ! -f android/gradlew ] || \
   [ ! -f android/gradle/wrapper/gradle-wrapper.jar ] || \
   [ ! -f android/app/src/main/res/values/styles.xml ]; then
  echo "Android scaffold incomplete - regenerating with scripts/bootstrap.sh"
  bash scripts/bootstrap.sh
fi

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
