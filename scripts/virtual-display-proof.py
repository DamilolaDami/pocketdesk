#!/usr/bin/env python3
"""Bounded, local native evidence for #52. Only manipulates probe-owned processes/windows."""
import argparse
import json
import pathlib
import subprocess
import time


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def eventually(check, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise RuntimeError("Timed out waiting for native display/window state")


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()
    binary = str(args.binary.resolve(strict=True))
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def command(name, *flags):
        report = out / f"{name}.json"
        with (out / f"{name}.log").open("w") as log:
            subprocess.run([binary, *flags, "--report", str(report)], stdout=log, stderr=log, check=True, timeout=50)
        return read(report)

    baseline = command("baseline", "--inventory")["final"]
    summary = {"hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
               "cycles": False, "fallback": False, "ownerExit": {}, "baselineRestored": False}
    try:
        cycles = command("cycles", "--cycles", "3")
        summary["cycles"] = len(cycles["cycles"]) == 3 and cycles["final"] == baseline
        fallback = command("unavailable", "--simulate-unavailable")
        summary["fallback"] = not fallback["available"] and fallback["physicalFallbackCaptured"] and fallback["final"] == baseline
        for kind in ["terminate", "kill"]:
            owner = helper = None
            log = (out / f"{kind}-owner.log").open("w")
            helper_log = (out / f"{kind}-window.log").open("w")
            owner_report = out / f"{kind}-owner.json"
            window_report = out / f"{kind}-window.json"
            # A prior run's checkpoint must never be mistaken for the new process.
            owner_report.unlink(missing_ok=True)
            window_report.unlink(missing_ok=True)
            try:
                owner = subprocess.Popen([binary, "--cycles", "1", "--hold-seconds", "120", "--report", str(owner_report)], stdout=log, stderr=log)

                def created():
                    data = read(owner_report)
                    if owner.poll() is not None:
                        raise RuntimeError(f"Owner exited before hold: {owner.returncode}")
                    return data if data and data["cycles"] and data["cycles"][0]["captureActiveDuringHold"] else None

                data = eventually(created)
                display_id = data["cycles"][0]["displayID"]
                helper = subprocess.Popen([binary, "--surface-display", str(display_id), "--report", str(window_report)], stdout=helper_log, stderr=helper_log)
                eventually(lambda: (read(window_report) or {}).get("onVirtualDisplay"))
                getattr(owner, kind)()
                owner.wait(timeout=5)

                def restored():
                    inventory = command(f"{kind}-after", "--inventory")
                    window = read(window_report) or {}
                    return inventory["final"] == baseline and not window.get("onVirtualDisplay", True) and window.get("visibleOnOtherDisplays", False)

                summary["ownerExit"][kind] = eventually(restored)
            finally:
                stop(helper)
                stop(owner)
                helper_log.close()
                log.close()
        summary["baselineRestored"] = command("final", "--inventory")["final"] == baseline
        if not (summary["cycles"] and summary["fallback"] and all(summary["ownerExit"].values()) and summary["baselineRestored"]):
            raise RuntimeError("One or more proof checks failed")
    except Exception as error:
        summary["error"] = str(error)
        raise
    finally:
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
