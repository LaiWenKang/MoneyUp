#!/usr/bin/env python3
"""Compare two real Core checkouts using the same labelled logging fixtures.

Requires macOS and a selected Xcode Swift compiler; no Python packages needed.
Builds finish before measurements; benchmark runs alternate order to reduce bias.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def fingerprint(root: Path, harness: Path, fixture: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted((root / "Sources/MoneyUpCore").glob("*.swift")):
        digest.update(path.name.encode() + b"\0" + path.read_bytes())
    digest.update(harness.read_bytes())
    digest.update(fixture.read_bytes())
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True, help="Checkout of the previous source")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if platform.system() != "Darwin" or not 1 <= args.runs <= 10:
        parser.error("Use macOS with Xcode and a run count between 1 and 10")
    current = Path(__file__).resolve().parents[2]
    baseline = args.baseline.resolve()
    for root in (baseline, current):
        if not (root / "Sources/MoneyUpCore/NaturalLanguageEntryParser.swift").is_file():
            parser.error(f"No MoneyUp Core source at {root}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    template = Path(__file__).with_name("logging.swift.template")
    harness = output / "logging.swift"
    harness.write_bytes(template.read_bytes())
    fixture = current / "Tests/Fixtures/Logging/understanding.json"
    variants = {"baseline": baseline, "after": current}
    commands: dict[str, list[str]] = {}

    def build(label: str) -> None:
        flags = ["-D", "LOGGING_V2"] if label == "after" else []
        commands[label] = ["swiftc", "-O", "-parse-as-library", *flags,
            *map(str, sorted((variants[label] / "Sources/MoneyUpCore").glob("*.swift"))),
            str(harness), "-o", str(output / f"{label}-benchmark")]
        with (output / f"{label}-build.log").open("w") as log:
            subprocess.run(commands[label], check=True, stdout=log, stderr=subprocess.STDOUT)

    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(build, variants))
    runs: dict[str, list[dict]] = {label: [] for label in variants}
    for index in range(args.runs):
        order = ("baseline", "after") if index % 2 == 0 else ("after", "baseline")
        for label in order:
            path = output / f"{label}-{index + 1}.json"
            subprocess.run([str(output / f"{label}-benchmark"), str(fixture), str(path)], check=True)
            runs[label].append(json.loads(path.read_text()))
    metrics = ("correctFixtures", "fixtureCount", "fieldCorrectionsNeeded", "medianMilliseconds",
               "p95Milliseconds", "cpuSeconds", "peakResidentBytes")
    summary = {label: {key: statistics.median(run[key] for run in values) for key in metrics}
               for label, values in runs.items()}
    for label, root in variants.items():
        summary[label].update(runs=args.runs, iterationsPerFixturePerRun=100,
                              coreSourceAndFixtureSHA256=fingerprint(root, harness, fixture))
    summary["swiftVersion"] = subprocess.check_output(["swiftc", "--version"], text=True).strip()
    summary["environment"] = platform.platform()
    summary["scope"] = ("Targeted fixtures, not population accuracy. Corrections are field discrepancies, "
        "not observed phone taps. Each warm interpretation includes output extraction and an autorelease "
        "pool. CPU and peak RSS cover the whole benchmark process. Values are medians across runs.")
    (output / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
