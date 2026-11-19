#!/usr/bin/env bash
# Generates Flutter platform folders without overwriting ARIFA's custom files.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/lib" "$TMP/android"
cp -a lib/. "$TMP/lib/"
cp -a android/. "$TMP/android/"

# These Gradle files are tracked in the repo because Flutter 3.24's generated
# defaults (AGP 7.3 / Kotlin 1.7 / Gradle 7.6.3) are too old for the plugins
# ARIFA uses. Keep them in the backup so flutter create cannot overwrite them.
GRADLE_FILES=(
  "settings.gradle"
  "build.gradle"
  "gradle.properties"
  "gradle/wrapper/gradle-wrapper.properties"
  "app/build.gradle"
)

flutter create --org com.example --project-name arifa .

# Restore ARIFA sources over Flutter's template defaults.
mkdir -p lib android/app/src/main/kotlin/com/example/arifa
mkdir -p android/app/src/main/res/xml android/app/src/main/res/values
cp -a "$TMP/lib/." lib/
cp "$TMP/android/app/src/main/AndroidManifest.xml" android/app/src/main/
cp "$TMP"/android/app/src/main/kotlin/com/example/arifa/*.kt \
   android/app/src/main/kotlin/com/example/arifa/
cp "$TMP/android/app/src/main/res/xml/accessibility_service_config.xml" \
   android/app/src/main/res/xml/
cp "$TMP/android/app/src/main/res/values/strings.xml" \
   android/app/src/main/res/values/

# Restore the pinned Gradle toolchain over flutter create's defaults.
for g in "${GRADLE_FILES[@]}"; do
  mkdir -p "android/$(dirname "$g")"
  cp "$TMP/android/$g" "android/$g"
done

if [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/flutter" ]; then
  bash scripts/termux_config.sh
fi

flutter pub get
echo "ARIFA bootstrap complete. Open the app, enter keys in Settings, then run scripts/build_apk.sh."
