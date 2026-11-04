#!/bin/bash
# Installs the Android command-line tools, platform-tools, Emulator 37.2.12 and
# the API 35 Google Play ARM64 system image into <project>/.runtime/android-sdk.
# Downloads from Google (dl.google.com); by running it you accept the Android
# SDK license terms. Versions are pinned because egw-host verifies them.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$ANDROID_HOME/cmdline-tools" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME" "$EGW_ROOT/.runtime/downloads"
archive="$EGW_ROOT/.runtime/downloads/commandlinetools-mac_arm64-16111833_latest.zip"
if [ ! -x "$ANDROID_HOME/cmdline-tools/23.0/bin/android" ]; then
  if [ ! -f "$archive" ]; then
    curl --fail --location --output "$archive" \
      https://dl.google.com/android/repository/commandlinetools-mac_arm64-16111833_latest.zip
  fi
  actual_sha1="$(shasum -a 1 "$archive" | awk '{print $1}')"
  [ "$actual_sha1" = ad03dc49bfacfd52c110b14104ea548b8a07e830 ] || { echo "command-line tools checksum mismatch" >&2; exit 1; }
  staging="$(mktemp -d "$EGW_ROOT/.runtime/cli-extract.XXXXXX")"
  ditto -x -k "$archive" "$staging"
  mv "$staging/cmdline-tools" "$ANDROID_HOME/cmdline-tools/23.0"
  rmdir "$staging"
fi
android --no-metrics --sdk="$ANDROID_HOME" sdk install platform-tools@37.0.1
android --no-metrics --sdk="$ANDROID_HOME" sdk install emulator@37.2.12
android --no-metrics --sdk="$ANDROID_HOME" sdk install 'system-images/android-35/google_apis_playstore/arm64-v8a@9'
echo "Done. Next: scripts/create-avd.sh"
