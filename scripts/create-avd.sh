#!/bin/bash
# Creates the AVD named in egw.config.json: API 35 Google Play ARM64,
# 1280x720 landscape, 4 cores, 4 GiB RAM, host GPU, 24 GiB data partition.
# Needs Java 17 for avdmanager. Never overwrites an existing AVD.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME"
if [ -e "$ANDROID_AVD_HOME/$EGW_AVD.ini" ] || [ -e "$ANDROID_AVD_HOME/$EGW_AVD.avd" ]; then
  echo "AVD already exists: $EGW_AVD (not overwriting)" >&2
  exit 1
fi
command -v avdmanager >/dev/null || { echo "avdmanager not found; run scripts/setup-runtime.sh (needs Java 17)" >&2; exit 1; }
printf 'no\n' | avdmanager create avd \
  --name "$EGW_AVD" \
  --package 'system-images;android-35;google_apis_playstore;arm64-v8a' \
  --device pixel_7 \
  --path "$ANDROID_AVD_HOME/$EGW_AVD.avd"
python3 -I - "$ANDROID_AVD_HOME/$EGW_AVD.avd/config.ini" "$EGW_AVD" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
values = {
    'PlayStore.enabled': 'yes', 'AvdId': sys.argv[2], 'avd.ini.displayname': sys.argv[2],
    'hw.cpu.ncore': '4', 'hw.ramSize': '4096',
    'hw.lcd.width': '1280', 'hw.lcd.height': '720', 'hw.lcd.density': '320',
    'hw.initialOrientation': 'landscape',
    'hw.gpu.enabled': 'yes', 'hw.gpu.mode': 'host', 'hw.keyboard': 'yes',
    'disk.dataPartition.size': str(24 * 1024**3),
    'hw.camera.back': 'none', 'hw.camera.front': 'none',
    'showDeviceFrame': 'no', 'skin.dynamic': 'yes',
}
lines = [line for line in path.read_text().splitlines() if line.split('=', 1)[0].strip() not in values]
path.write_text('\n'.join(lines + [f'{k}={v}' for k, v in values.items()]) + '\n')
PY
echo "Created AVD: $EGW_AVD. Next: scripts/egw build && scripts/egw start --window"
