#!/bin/bash
# Source this file (bash, not zsh). All Android state stays inside <project>/.runtime.
EGW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EGW_ROOT
export ANDROID_HOME="$EGW_ROOT/.runtime/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$EGW_ROOT/.runtime/android-user"
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_AVD_HOME="$EGW_ROOT/.runtime/avd"
# Java is only needed by sdkmanager/avdmanager (setup), not to run the emulator.
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
fi
[ -n "$JAVA_HOME" ] && export JAVA_HOME && PATH="$JAVA_HOME/bin:$PATH"
export PATH="$ANDROID_HOME/cmdline-tools/23.0/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
# Machine-specific values: egw.config.json (see egw.config.example.json).
EGW_AVD="$(python3 -I "$EGW_ROOT/scripts/host_config.py" get avd)" || return 1
EGW_CONSOLE_PORT="$(python3 -I "$EGW_ROOT/scripts/host_config.py" get consolePort)" || return 1
EGW_GRPC_PORT="$(python3 -I "$EGW_ROOT/scripts/host_config.py" get grpcPort)" || return 1
export EGW_AVD EGW_CONSOLE_PORT EGW_GRPC_PORT
