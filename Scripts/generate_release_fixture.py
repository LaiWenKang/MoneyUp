#!/usr/bin/env python3
"""Generate deterministic fictional transactions for MoneyUp device-scale QA."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator


DEFAULT_ENTRY_COUNT = 10_000
MAXIMUM_ENTRY_COUNT = 20_000
HEADERS = ("id", "date", "kind", "amount", "payee", "note")
START = datetime(2019, 1, 1, tzinfo=timezone.utc)
STEP = timedelta(hours=4)


def fixture_rows(entry_count: int) -> Iterator[dict[str, str]]:
    """Yield stable importer-compatible rows containing no real user data."""
    if not 1 <= entry_count <= MAXIMUM_ENTRY_COUNT:
        raise ValueError(
            f"entry count must be between 1 and {MAXIMUM_ENTRY_COUNT:,}"
        )

    for index in range(entry_count):
        cents = 100 + ((index * 7_919) % 9_900)
        occurred_at = START + STEP * index
        yield {
            "id": f"moneyup-release-fixture-{index + 1:05d}",
            "date": occurred_at.isoformat(timespec="seconds").replace("+00:00", "Z"),
            "kind": "expense",
            "amount": f"{cents // 100}.{cents % 100:02d}",
            "payee": f"Fixture Merchant {(index % 97) + 1:02d}",
            "note": "Synthetic release-scale data",
        }


def write_fixture(output: Path, entry_count: int = DEFAULT_ENTRY_COUNT) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=HEADERS,
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(fixture_rows(entry_count))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--entries",
        type=int,
        default=DEFAULT_ENTRY_COUNT,
        help=f"number of rows (1-{MAXIMUM_ENTRY_COUNT:,}; default: {DEFAULT_ENTRY_COUNT:,})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(f"MoneyUp-Release-Fixture-{DEFAULT_ENTRY_COUNT}.csv"),
        help="destination CSV path",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        write_fixture(args.output, args.entries)
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error
    print(f"Generated {args.entries:,} fictional entries at {args.output}")


if __name__ == "__main__":
    main()
