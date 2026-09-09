#!/usr/bin/env python3
"""Run one bounded batch review smoke test on every installed iPhone profile.

Creates disposable devices only. Optional configured iPads are compatibility
checks, not a claim that MoneyUp has a native iPad layout. No existing simulator
or physical-device installation is erased or modified.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import subprocess
import time
from pathlib import Path


def capture(*args: str) -> str:
    return subprocess.check_output(args, text=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-products", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--configured-ipads", action="store_true")
    args = parser.parse_args()
    if not args.test_products.exists() or not 1 <= args.workers <= 2:
        parser.error("Supply built test products and one or two workers")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(capture("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    configured = json.loads(capture("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    inventory = []
    for runtime in runtimes:
        if not runtime.get("isAvailable") or not runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS"):
            continue
        configured_types = {d["deviceTypeIdentifier"] for d in configured.get(runtime["identifier"], [])}
        for model in runtime.get("supportedDeviceTypes", []):
            if model["productFamily"] == "iPhone" or (args.configured_ipads and model["productFamily"] == "iPad" and model["identifier"] in configured_types):
                inventory.append({"name": model["name"], "type": model["identifier"], "runtime": runtime["identifier"],
                    "os": runtime["version"], "family": model["productFamily"]})
    (output / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")

    def run(model: dict) -> dict:
        slug = re.sub(r"[^a-z0-9]+", "-", model["name"].lower()).strip("-") + "-" + model["os"]
        directory = output / slug
        directory.mkdir(exist_ok=True)
        result = dict(model, simulated=True, status="failed")
        device = None
        started = time.monotonic()
        try:
            device = capture("xcrun", "simctl", "create", "MoneyUp Batch QA " + model["name"], model["type"], model["runtime"]).strip()
            result["temporaryDeviceID"] = device
            with (directory / "test.log").open("w") as log:
                command = ["xcodebuild", "test-without-building", "-testProductsPath", str(args.test_products.resolve()),
                    "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                    "-only-testing:MoneyUpTests/BatchDeviceCoverageTests", "-resultBundlePath", str(directory / "result.xcresult")]
                completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=240)
                result["exitCode"] = completed.returncode
            bundle = directory / "result.xcresult"
            if bundle.exists():
                summary = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"))
                (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                result["passedTests"] = summary.get("passedTests", 0)
                result["failedTests"] = summary.get("failedTests", 0)
                result["status"] = "passed" if completed.returncode == 0 and result["passedTests"] == 1 and result["failedTests"] == 0 else "failed"
                with (directory / "export.log").open("w") as log:
                    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(directory / "attachments")], stdout=log, stderr=subprocess.STDOUT, check=True)
                for path in (directory / "attachments").glob("*.json"):
                    payload = json.loads(path.read_text())
                    if isinstance(payload, dict) and payload.get("simulated") is True:
                        result["observation"] = payload
            result["evidenceDirectory"] = str(directory)
        except (subprocess.SubprocessError, OSError, ValueError) as error:
            result["error"] = str(error)
        finally:
            if device:
                # This UUID came only from this job's create call.
                subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["xcrun", "simctl", "delete", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            result["elapsedSeconds"] = round(time.monotonic() - started, 3)
            (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({"device": model["name"], "status": result["status"], "seconds": result["elapsedSeconds"]}), flush=True)
        return result

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for result in pool.map(run, inventory):
            results.append(result)
            (output / "matrix.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps({"total": len(results), "passed": sum(r["status"] == "passed" for r in results),
        "note": "Simulator observations share host hardware. Older runtimes and physical phones were not tested."}), flush=True)


if __name__ == "__main__":
    main()
