"""Machine-specific settings; mirrors Sources/EGWHost/HostConfig.swift.

Reads <project>/egw.config.json. Every key is optional; an unsafe or invalid
file is ignored (defaults are used) and `problem` says why.
CLI: `python3 -I host_config.py get <key>` prints one value (exit 1 on a bad file),
     `python3 -I host_config.py json` prints all values.
"""
import json
import os
from pathlib import Path
import re
import stat
import sys

PROJECT = Path(__file__).resolve().parents[1]
FILE_NAME = "egw.config.json"
DEFAULTS = {"avd": "egw_api35_arm64", "grpcPort": 8554, "consolePort": 5554,
            "bundleIdentifier": "local.egw-launcher", "appName": "EmuGameWindow"}


def invalid_reason(c):
    if not isinstance(c["avd"], str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", c["avd"]):
        return "avd"
    for key in ("grpcPort", "consolePort"):
        if type(c[key]) is not int:
            return key
    if not 1024 <= c["grpcPort"] <= 65535:
        return "grpcPort"
    if not (5554 <= c["consolePort"] <= 5682 and c["consolePort"] % 2 == 0):
        return "consolePort"
    if c["grpcPort"] in (c["consolePort"], c["consolePort"] + 1):
        return "grpcPort"
    b = c["bundleIdentifier"]
    if not isinstance(b, str) or len(b) > 128 or not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", b):
        return "bundleIdentifier"
    a = c["appName"]
    if (not isinstance(a, str) or not a or len(a) > 40 or "/" in a or ":" in a
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in a)):
        return "appName"
    return None


def load(project=PROJECT):
    """Returns (config dict, problem or None)."""
    path = Path(project) / FILE_NAME
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return dict(DEFAULTS), None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o022 or info.st_size > 4096):
        return dict(DEFAULTS), "unsafe_file"
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return dict(DEFAULTS), "unreadable"
    if not isinstance(raw, dict):
        return dict(DEFAULTS), "unreadable"
    config = dict(DEFAULTS)
    config.update({k: v for k, v in raw.items() if k in DEFAULTS})
    reason = invalid_reason(config)
    if reason:
        return dict(DEFAULTS), "invalid_" + reason
    return config, None


def main(argv):
    config, problem = load()
    if problem:
        print("egw.config.json 無法使用（%s）；請修正後再試。" % problem, file=sys.stderr)
        return 1
    if len(argv) == 3 and argv[1] == "get" and argv[2] in config:
        print(config[argv[2]])
        return 0
    if len(argv) == 2 and argv[1] == "json":
        print(json.dumps(config, ensure_ascii=False))
        return 0
    print("用法：host_config.py get <key> | json", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
