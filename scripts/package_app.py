#!/usr/bin/env python3
"""Package the launcher app into .runtime/state/app/<appName>.app (ad-hoc signed).

Keeps the previous bundle as App-build-<stamp>.app next to it; never launches,
installs or deletes anything. The app needs no TCC permission.
"""
import datetime
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host_config", Path(__file__).with_name("host_config.py"))
host_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host_config)


def main():
    binary = ROOT / ".build/arm64-apple-macosx/debug/egw-host"
    if not binary.is_file():
        raise SystemExit("Build first: egw build")
    config, problem = host_config.load(ROOT)
    if problem:
        raise SystemExit("egw.config.json is not usable (%s)." % problem)
    manifest = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    assert manifest.get("EGWRole") == "launcher"
    manifest["CFBundleIdentifier"] = config["bundleIdentifier"]
    manifest["CFBundleDisplayName"] = config["appName"]
    manifest["CFBundleName"] = config["appName"][:15]
    manifest["EGWProjectRoot"] = str(ROOT)
    parent = ROOT / ".runtime/state/app"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    bundle = parent / (config["appName"] + ".app")
    if bundle.is_symlink():
        raise SystemExit("%s is a symlink; not touching it." % bundle)
    if bundle.exists():
        names = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True, timeout=5).splitlines()
        if str(bundle / "Contents/MacOS/egw-host") in {name.strip() for name in names}:
            raise SystemExit("The app is running; close it first.")
        stamp = datetime.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
        archive = parent / ("App-build-" + stamp + ".app")
        bundle.rename(archive)  # kept; `egw clean` keeps the newest two
        print("Previous bundle kept: %s" % archive)
    executable = bundle / "Contents/MacOS/egw-host"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(manifest))
    for command in (["/usr/bin/plutil", "-lint", str(bundle / "Contents/Info.plist")],
                    ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", config["bundleIdentifier"], str(bundle)],
                    ["/usr/bin/codesign", "--verify", "--strict", str(bundle)]):
        if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT).returncode:
            raise SystemExit("Packaging step failed: %s" % " ".join(command[:2]))
    print("Packaged: %s (not opened)" % bundle)


if __name__ == "__main__":
    os.umask(0o077)
    main()
