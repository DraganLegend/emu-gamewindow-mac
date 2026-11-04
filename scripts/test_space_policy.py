"""Same vectors as Tests/EGWHostTests/SpaceTests.swift. Run: python3 -I test_space_policy.py"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("space_policy", Path(__file__).with_name("space_policy.py"))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
G = sp.GIB


def check():
    r = sp.thresholds(20 * G, 24 * G, 17 * G)
    assert (r["avd_remaining_bytes"], r["stop_bytes"], r["warn_bytes"], r["level"]) == (7 * G, 15 * G, 22 * G, "warn")
    assert sp.thresholds(14 * G, 24 * G, 17 * G)["level"] == "stop"
    assert sp.thresholds(30 * G, 24 * G, 17 * G)["level"] == "ok"
    full = sp.thresholds(10 * G, 24 * G, 25 * G)
    assert (full["stop_bytes"], full["warn_bytes"], full["level"]) == (8 * G, 15 * G, "warn")
    unknown = sp.thresholds(25 * G, None, 17 * G)
    assert unknown["fallback"] and (unknown["stop_bytes"], unknown["warn_bytes"], unknown["level"]) == (20 * G, 27 * G, "warn")
    assert sp.data_partition_bytes("a=1\ndisk.dataPartition.size=25769803776\n") == 25769803776
    assert sp.data_partition_bytes("disk.dataPartition.size = 24G") == 24 * G
    assert sp.data_partition_bytes("disk.dataPartition.size=6144MB") == 6 * G
    assert sp.data_partition_bytes("disk.dataPartition.size=lots") is None
    assert sp.data_partition_bytes("disk.dataPartition.size=-5") is None
    assert sp.data_partition_bytes("disk.cachePartition.size=66MB") is None
    print("space_policy.py: 12 checks passed")


if __name__ == "__main__":
    check()
