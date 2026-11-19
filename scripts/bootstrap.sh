#!/usr/bin/env bash
# Generates Flutter platform folders without overwriting ARIFA's custom files.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/lib" "$TMP/android"
cp -a lib/. "$TMP/lib/"
# The Android scaffold may be absent on a fresh checkout; flutter create below
# regenerates it. Only back it up when it exists so `set -e` cannot abort here.
if [ -d android ]; then
  cp -a android/. "$TMP/android/"
fi

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

flutter create --org com.arifa.app --project-name arifa --platforms android .

# Restore ARIFA sources over Flutter's template defaults. Kotlin sources live
# under the namespace declared in android/app/build.gradle: com.arifa.app.arifa.
mkdir -p lib android/app/src/main/kotlin/com/arifa/app/arifa
mkdir -p android/app/src/main/res/xml android/app/src/main/res/values
cp -a "$TMP/lib/." lib/
if [ -f "$TMP/android/app/src/main/AndroidManifest.xml" ]; then
  cp "$TMP/android/app/src/main/AndroidManifest.xml" android/app/src/main/
fi
if compgen -G "$TMP/android/app/src/main/kotlin/com/arifa/app/arifa/*.kt" > /dev/null; then
  cp "$TMP"/android/app/src/main/kotlin/com/arifa/app/arifa/*.kt \
     android/app/src/main/kotlin/com/arifa/app/arifa/
fi
if [ -f "$TMP/android/app/src/main/res/xml/accessibility_service_config.xml" ]; then
  cp "$TMP/android/app/src/main/res/xml/accessibility_service_config.xml" \
     android/app/src/main/res/xml/
fi
if [ -f "$TMP/android/app/src/main/res/values/strings.xml" ]; then
  cp "$TMP/android/app/src/main/res/values/strings.xml" \
     android/app/src/main/res/values/
fi

# Restore the pinned Gradle toolchain over flutter create's defaults.
for g in "${GRADLE_FILES[@]}"; do
  if [ -f "$TMP/android/$g" ]; then
    mkdir -p "android/$(dirname "$g")"
    cp "$TMP/android/$g" "android/$g"
  fi
done

if [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/flutter" ]; then
  bash scripts/termux_config.sh
fi

# Launcher mipmaps must always come from assets/icon/arifa_icon.png.
python3 scripts/generate_icon.py

flutter pub get
echo "ARIFA bootstrap complete. Open the app, enter keys in Settings, then run scripts/build_apk.sh."
