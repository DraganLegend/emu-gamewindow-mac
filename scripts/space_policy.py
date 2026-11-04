"""Disk thresholds; mirrors Sources/EGWHost/SpacePolicy.swift.

stop = AVD remaining growth + 8 GiB, warn = AVD remaining growth + 15 GiB.
The AVD userdata image only grows, up to disk.dataPartition.size. If the AVD
numbers cannot be read (no AVD yet), the lines assume 12 GiB of growth:
stop 20 GiB, warn 27 GiB.
Usable as a module or as `python3 -I space_policy.py [check|json]`.
"""
import json
import os
from pathlib import Path
import sys

GIB = 1024 ** 3
STOP_MARGIN = 8 * GIB
WARN_MARGIN = 15 * GIB
FALLBACK_STOP = 20 * GIB
FALLBACK_WARN = 27 * GIB
sys.path.insert(0, str(Path(__file__).resolve().parent))
import host_config  # noqa: E402  (same directory; -I keeps the script dir off sys.path)

PROJECT = host_config.PROJECT
AVD_DIR = PROJECT / ".runtime/avd" / (host_config.load()[0]["avd"] + ".avd")


def data_partition_bytes(text):
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if not sep or key.strip() != "disk.dataPartition.size":
            continue
        value = value.strip().upper()
        unit = 1
        for suffix, factor in (("GB", GIB), ("MB", 1024 ** 2), ("KB", 1024), ("G", GIB), ("M", 1024 ** 2), ("K", 1024)):
            if value.endswith(suffix):
                unit, value = factor, value[: -len(suffix)]
                break
        if not value.isdigit() or int(value) <= 0:
            return None
        return int(value) * unit
    return None


def allocated(path):
    try:
        info = os.lstat(path)
    except OSError:
        return None
    import stat
    return info.st_blocks * 512 if stat.S_ISREG(info.st_mode) else None


def thresholds(free_bytes, avd_max, avd_current):
    if avd_max is None or avd_current is None:
        remaining = None
        stop, warn = FALLBACK_STOP, FALLBACK_WARN
    else:
        remaining = max(0, avd_max - avd_current)
        stop, warn = remaining + STOP_MARGIN, remaining + WARN_MARGIN
    level = "stop" if free_bytes < stop else "warn" if free_bytes < warn else "ok"
    return {"free_bytes": free_bytes, "stop_bytes": stop, "warn_bytes": warn,
            "avd_remaining_bytes": remaining, "level": level, "fallback": remaining is None}


def current(project=PROJECT, avd_dir=AVD_DIR):
    fs = os.statvfs(project)
    free = fs.f_bavail * fs.f_frsize
    try:
        avd_max = data_partition_bytes((Path(avd_dir) / "config.ini").read_text())
    except OSError:
        avd_max = None
    return thresholds(free, avd_max, allocated(Path(avd_dir) / "userdata-qemu.img.qcow2"))


def _gib(value):
    return "%.1f GiB" % (value / GIB)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    result = current()
    if mode == "json":
        print(json.dumps(result))
        sys.exit(0)
    line = "立即空閒約 %s（警告線 %s、停止線 %s）" % (
        _gib(result["free_bytes"]), _gib(result["warn_bytes"]), _gib(result["stop_bytes"]))
    if result["level"] == "stop":
        print(line + "：低於停止線，停止。", file=sys.stderr)
        sys.exit(1)
    print(line + ("：接近警告線，建議執行 egw space／egw clean。" if result["level"] == "warn" else "。"))
