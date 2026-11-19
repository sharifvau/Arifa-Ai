#!/usr/bin/env bash
# Applies the Termux/aarch64 Gradle tweaks ARIFA needs after `flutter create`.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${PREFIX:-}" ]; then
  echo "PREFIX is empty - this script is for Termux only." >&2
  exit 1
fi

# The patched Flutter .deb ships a helper that knows the exact aapt2/SDK paths.
if [ -x "$PREFIX/share/flutter/flutter_project_config.sh" ]; then
  bash "$PREFIX/share/flutter/flutter_project_config.sh"
  echo "Used Flutter SDK's flutter_project_config.sh"
else
  echo "SDK helper not found - applying ARIFA fallback config."
fi

python3 - "$PREFIX" <<'PY'
import os
import re
import sys
from pathlib import Path

prefix = sys.argv[1]

# 1) gradle.properties
gp = Path("android/gradle.properties")
text = gp.read_text(encoding="utf-8") if gp.exists() else ""
lines = [l for l in text.splitlines()
         if not re.match(r"^(org\.gradle\.jvmargs|android\.useAndroidX|android\.aapt2FromMavenOverride|android\.enableResourceOptimizations)=", l)]
aapt2 = f"{prefix}/bin/aapt2"
lines += [
    "org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m",
    "android.useAndroidX=true",
]
# Only point Gradle at aapt2 when the binary actually exists; otherwise let
# the Android Gradle Plugin resolve its own aapt2 from Maven (AUDIT L6).
if Path(aapt2).exists():
    lines.append(f"android.aapt2FromMavenOverride={aapt2}")
else:
    print(f"WARNING: aapt2 not found at {aapt2}; using AGP's Maven aapt2")
lines.append("android.enableResourceOptimizations=false")
gp.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")

# 2) app/build.gradle (Groovy, not build.gradle.kts) - ARM64 only, no
#    minify/resource shrink (Termux RAM). Keep the repo's SDK 34 pins.
bg = Path("android/app/build.gradle")
if bg.exists():
    s = bg.read_text(encoding="utf-8")
    # Termux aapt2 expects these levels; do NOT bump past the compileSdk 34 pin.
    s = re.sub(r"compileSdk\s*=\s*\d+", "compileSdk = 34", s, count=1)
    s = re.sub(r"targetSdk\s*=\s*\d+", "targetSdk = 34", s, count=1)
    if "abiFilters" not in s:
        s = re.sub(
            r"(defaultConfig\s*\{)",
            r'\1\n        ndk {\n            abiFilters "arm64-v8a"\n        }',
            s,
            count=1,
        )
    if "minifyEnabled" not in s:
        s = re.sub(
            r"(buildTypes\s*\{[\s\S]*?release\s*\{)",
            r"\1\n            minifyEnabled false\n            shrinkResources false",
            s,
            count=1,
        )
    bg.write_text(s, encoding="utf-8")

# 3) local.properties (only if the SDK helper did not create one)
lp = Path("android/local.properties")
if not lp.exists():
    sdk = os.environ.get("ANDROID_SDK_ROOT") or f"{prefix}/opt/android-sdk"
    lp.write_text(f"sdk.dir={sdk}\n", encoding="utf-8")

print("ARIFA Termux Gradle config applied.")
PY
