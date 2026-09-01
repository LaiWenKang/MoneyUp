#!/usr/bin/env python3
"""Generate deterministic fictional transactions for MoneyUp device-scale QA."""

from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator


DEFAULT_ENTRY_COUNT = 10_000
MAXIMUM_ENTRY_COUNT = 20_000
HEADERS = ("id", "date", "kind", "amount", "payee", "note")
INTELLIGENCE_HEADERS = (
    "id", "day", "kind", "amount", "currency", "payee_key",
    "account_id", "category_id", "secondary_category_id",
    "destination_account_id", "shape", "scenario",
)
START = datetime(2019, 1, 1, tzinfo=timezone.utc)
STEP = timedelta(hours=4)
INTELLIGENCE_AS_OF_DAY = 20260831


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


def deterministic_uuid(value: int) -> str:
    return f"00000000-0000-0000-0000-{value:012d}"


def intelligence_row(
    entry_number: int,
    day: int,
    amount: str,
    payee_key: str,
    account_number: int,
    category_number: int | None,
    scenario: str,
    *,
    kind: str = "expense",
    currency: str = "SGD",
    shape: str = "single",
    secondary_category_number: int | None = None,
    destination_account_number: int | None = None,
) -> dict[str, str]:
    return {
        "id": deterministic_uuid(entry_number),
        "day": str(day),
        "kind": kind,
        "amount": amount,
        "currency": currency,
        "payee_key": payee_key,
        "account_id": deterministic_uuid(account_number),
        "category_id": (
            deterministic_uuid(category_number) if category_number else ""
        ),
        "secondary_category_id": (
            deterministic_uuid(secondary_category_number)
            if secondary_category_number else ""
        ),
        "destination_account_id": (
            deterministic_uuid(destination_account_number)
            if destination_account_number else ""
        ),
        "shape": shape,
        "scenario": scenario,
    }


def planted_intelligence_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    entry_number = 1

    def append_series(
        scenario: str,
        days: list[int],
        amounts: list[str],
        payee: str,
        account: int,
        category: int,
        currency: str = "SGD",
    ) -> None:
        nonlocal entry_number
        for day, amount in zip(days, amounts, strict=True):
            rows.append(intelligence_row(
                entry_number, day, amount, payee, account, category,
                scenario, currency=currency,
            ))
            entry_number += 1

    append_series(
        "monthly_recurrence",
        [20260310, 20260410, 20260510, 20260610, 20260710, 20260810],
        ["20.00"] * 6,
        "oracle monthly",
        100_001,
        200_001,
    )
    append_series(
        "lapsed_weekly",
        [20260501, 20260508, 20260515, 20260522, 20260529, 20260605],
        ["8.00"] * 6,
        "oracle weekly",
        100_002,
        200_002,
        "USD",
    )
    append_series(
        "price_increase",
        [20260115, 20260215, 20260315, 20260415],
        ["20.000", "20.000", "20.000", "30.000"],
        "oracle stepped price",
        100_003,
        200_003,
        "KWD",
    )
    for _ in range(2):
        rows.append(intelligence_row(
            entry_number, 20260820, "12.50", "oracle duplicate",
            100_004, 200_004, "exact_duplicate",
        ))
        entry_number += 1
    append_series(
        "category_anomaly",
        [20260701, 20260702, 20260703, 20260704, 20260705,
         20260706, 20260707, 20260708, 20260801],
        ["10.00"] * 8 + ["100.00"],
        "oracle category history",
        100_005,
        200_005,
    )
    rows.append(intelligence_row(
        entry_number, 20260805, "5.00", "oracle refund",
        100_001, 200_001, "refund", kind="refund",
    ))
    entry_number += 1
    rows.append(intelligence_row(
        entry_number, 20260806, "25.00", "oracle transfer",
        100_001, None, "transfer", kind="transfer", shape="transfer",
        destination_account_number=100_002,
    ))
    entry_number += 1
    rows.append(intelligence_row(
        entry_number, 20260807, "30.00", "oracle split",
        100_001, 200_006, "split", shape="split",
        secondary_category_number=200_007,
    ))
    entry_number += 1
    append_series(
        "irregular_cadence",
        [20260101, 20260109, 20260214, 20260430],
        ["14.00"] * 4,
        "oracle irregular",
        100_006,
        200_008,
    )
    for account in (100_007, 100_008):
        rows.append(intelligence_row(
            entry_number, 20260821, "18.00", "oracle near duplicate",
            account, 200_009, "different_account_near_duplicate",
        ))
        entry_number += 1
    append_series(
        "insufficient_anomaly_history",
        [20260711, 20260712, 20260713, 20260714,
         20260715, 20260716, 20260717, 20260802],
        ["9.00"] * 7 + ["90.00"],
        "oracle short history",
        100_009,
        200_010,
    )
    return rows


def intelligence_fixture_rows(entry_count: int) -> Iterator[dict[str, str]]:
    planted = planted_intelligence_rows()
    if not len(planted) <= entry_count <= MAXIMUM_ENTRY_COUNT:
        raise ValueError(
            f"intelligence entry count must be between {len(planted)} "
            f"and {MAXIMUM_ENTRY_COUNT:,}"
        )
    yield from planted
    currencies = ("SGD", "USD", "KWD")
    for index in range(entry_count - len(planted)):
        occurred_at = START + STEP * index
        yield intelligence_row(
            1_000_000 + index,
            int(occurred_at.strftime("%Y%m%d")),
            "50.00" if currencies[index % 3] != "KWD" else "50.000",
            f"filler merchant {index + 1:05d}",
            800_001 + (index % 9),
            900_001 + (index % 17),
            "scale_filler",
            currency=currencies[index % 3],
        )


def intelligence_oracle(entry_count: int) -> dict[str, object]:
    rows = planted_intelligence_rows()
    by_scenario: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        by_scenario.setdefault(row["scenario"], []).append(row)
    monthly = by_scenario["monthly_recurrence"][-1]["id"].lower()
    weekly = by_scenario["lapsed_weekly"][-1]["id"].lower()
    stepped = by_scenario["price_increase"][-1]["id"].lower()
    duplicate = by_scenario["exact_duplicate"]
    anomaly = by_scenario["category_anomaly"][-1]["id"].lower()
    expected = [
        {"id": f"recurrence:{monthly}", "kind": "recurrence", "rule_id": "INT-REC-001"},
        {"id": f"lapsed:{weekly}", "kind": "lapsed_subscription", "rule_id": "INT-REC-002"},
        {"id": f"lapsed:{stepped}", "kind": "lapsed_subscription", "rule_id": "INT-REC-002"},
        {"id": f"price:{stepped}", "kind": "price_increase", "rule_id": "INT-REC-003"},
        {
            "id": "duplicate:"
                f"{duplicate[0]['id'].lower()}:{duplicate[1]['id'].lower()}",
            "kind": "possible_duplicate",
            "rule_id": "INT-DUP-001",
        },
        {"id": f"anomaly:{anomaly}", "kind": "category_anomaly", "rule_id": "INT-ANO-001"},
    ]
    return {
        "as_of_day": INTELLIGENCE_AS_OF_DAY,
        "currencies": ["KWD", "SGD", "USD"],
        "expected_findings": sorted(expected, key=lambda item: item["id"]),
        "excluded_entry_ids": sorted(
            row["id"] for row in rows if row["shape"] in {"split", "transfer"}
        ),
        "negative_scenarios": [
            "different_account_near_duplicate",
            "insufficient_anomaly_history",
            "irregular_cadence",
        ],
        "planted_rows": rows,
        "profile": "intelligence-v1",
        "profile_entry_count": entry_count,
        "schema_version": 1,
    }


def write_intelligence_fixture(
    output: Path,
    oracle_output: Path,
    entry_count: int,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=INTELLIGENCE_HEADERS,
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(intelligence_fixture_rows(entry_count))
    oracle_output.parent.mkdir(parents=True, exist_ok=True)
    oracle_output.write_text(
        json.dumps(
            intelligence_oracle(entry_count),
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--profile",
        choices=("release", "intelligence"),
        default="release",
        help="release keeps the importer-compatible fixture; intelligence adds detector facts",
    )
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
    parser.add_argument(
        "--oracle",
        type=Path,
        help="intelligence oracle JSON path (defaults beside --output)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.profile == "intelligence":
            oracle = args.oracle or args.output.with_suffix(".oracle.json")
            write_intelligence_fixture(args.output, oracle, args.entries)
            print(
                f"Generated {args.entries:,} intelligence entries at "
                f"{args.output} with oracle {oracle}"
            )
            return
        if args.oracle is not None:
            raise ValueError("--oracle requires --profile intelligence")
        write_fixture(args.output, args.entries)
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error
    print(f"Generated {args.entries:,} fictional entries at {args.output}")


if __name__ == "__main__":
    main()
