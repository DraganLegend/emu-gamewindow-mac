#!/usr/bin/env python3
"""Build or test the host with SwiftPM. Usage: python3 -I scripts/build.py build|test

Stops below the disk stop line (space_policy.py). Each run writes its log to
.runtime/state/<stage>-<stamp>/swiftpm.log. Dependencies resolve from
Package.resolved; the first build downloads them from GitHub into .build/
(SwiftPM caches stay inside the project).
"""
import datetime
import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".runtime/state"
spec = importlib.util.spec_from_file_location("space_policy", Path(__file__).with_name("space_policy.py"))
space_policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(space_policy)


def testing_flags():
    # Command Line Tools ship Testing.framework outside SwiftPM's default search path.
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    frameworks = developer / "Library/Developer/Frameworks"
    if not (frameworks / "Testing.framework").is_dir():
        return []
    f = str(frameworks)
    return ["-Xswiftc", "-F", "-Xswiftc", f, "-Xlinker", "-F", "-Xlinker", f, "-Xlinker", "-rpath", "-Xlinker", f]


def main(argv):
    if len(argv) != 2 or argv[1] not in ("build", "test"):
        print("usage: build.py build|test", file=sys.stderr)
        return 64
    stage = argv[1]
    if space_policy.current(ROOT)["level"] == "stop":
        print("Not enough free disk space; see egw space.", file=sys.stderr)
        return 1
    stamp = datetime.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
    run = STATE / (stage + "-" + stamp)
    run.mkdir(parents=True, mode=0o700)
    common = ["--package-path", str(ROOT), "--scratch-path", str(ROOT / ".build"), "--jobs", "4",
              "--cache-path", str(ROOT / ".build/cache"), "--config-path", str(ROOT / ".build/config"),
              "--security-path", str(ROOT / ".build/security"),
              "--force-resolved-versions", "--skip-update"]
    if stage == "build":
        command = ["swift", "build", *common, "--product", "egw-host"]
    else:
        command = ["swift", "test", *common, "--disable-xctest", "--enable-swift-testing", *testing_flags()]
    with (run / "swiftpm.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    tail = (run / "swiftpm.log").read_text(errors="replace").splitlines()[-15:]
    print("\n".join(tail))
    print("%s %s; log: %s" % (stage, "passed" if result.returncode == 0 else "FAILED", run / "swiftpm.log"))
    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))
