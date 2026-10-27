#!/usr/bin/env python3
"""Bounded, local-only host CPU/RSS and machine-wide GPU counters for a named process."""
import argparse
import json
import pathlib
import plistlib
import subprocess
import time


def gpu_counters():
    result = subprocess.run(["/usr/sbin/ioreg", "-a", "-r", "-c", "IOAccelerator"], capture_output=True)
    if result.returncode:
        return None
    try:
        roots = plistlib.loads(result.stdout)
    except Exception:
        return None
    stack = list(roots)
    while stack:
        item = stack.pop()
        if not isinstance(item, dict):
            continue
        statistics = item.get("PerformanceStatistics")
        if statistics:
            return {key: statistics.get(key) for key in ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %", "In use system memory"]}
        stack.extend(item.get("IORegistryEntryChildren", []))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=30, choices=range(1, 121))
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0:
        parser.error("pid must identify one running process")
    model = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
    report = {"started_at_unix_seconds": time.time(), "model": model or None, "pid": args.pid, "gpu_scope": "whole_machine_not_process_attributed", "samples": []}
    began = time.monotonic()
    while time.monotonic() - began < args.seconds:
        result = subprocess.run(["/bin/ps", "-p", str(args.pid), "-o", "%cpu=,rss="], capture_output=True, text=True)
        values = result.stdout.split()
        if len(values) != 2:
            break
        report["samples"].append({"seconds": time.monotonic() - began, "ps_cpu_percent": float(values[0]),
                                   "resident_bytes": int(values[1]) * 1024, "gpu": gpu_counters()})
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        time.sleep(1)
    if not report["samples"]:
        raise SystemExit("No samples: check the process and command permissions")


if __name__ == "__main__":
    main()
