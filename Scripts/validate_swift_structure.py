#!/usr/bin/env python3
"""Enforce bounded Swift file, declaration-body, and function-body sizes."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_LINES = 1_200
MAX_TYPE_BODY_LINES = 600
MAX_FUNCTION_BODY_LINES = 80
TYPE_PATTERN = re.compile(
    r"(?m)^[ \t]*"
    r"(?:(?:public|internal|private|fileprivate|package|open|final|indirect|"
    r"nonisolated)\s+)*"
    r"(actor|class|struct|enum|protocol|extension)\s+"
    r"([A-Za-z_][A-Za-z0-9_\.]*)"
)
FUNCTION_PATTERN = re.compile(
    r"(?m)^[ \t]*(?:@[A-Za-z_][^\n]*\n[ \t]*)*"
    r"(?:(?:public|internal|private|fileprivate|package|open|final|static|"
    r"class|mutating|nonmutating|nonisolated|override|convenience|required|"
    r"prefix|postfix)\s+)*"
    r"(func\s+([A-Za-z_][A-Za-z0-9_]*|[/=+!*%<>&|^?~.\-]+)|"
    r"init\b|deinit\b|subscript\b)"
)


def mask_swift(source: str) -> str:
    """Mask comments and strings while preserving offsets and line breaks."""
    characters = list(source)
    index = 0
    block_depth = 0
    raw_hashes = 0
    state = "code"
    while index < len(characters):
        if state == "code":
            if source.startswith("//", index):
                characters[index : index + 2] = [" "] * 2
                index += 2
                state = "line_comment"
            elif source.startswith("/*", index):
                characters[index : index + 2] = [" "] * 2
                index += 2
                block_depth = 1
                state = "block_comment"
            elif characters[index] == "#":
                raw_end = index
                while raw_end < len(characters) and characters[raw_end] == "#":
                    raw_end += 1
                raw_hashes = raw_end - index
                if source.startswith('\"\"\"', raw_end):
                    characters[index : raw_end + 3] = [" "] * (raw_hashes + 3)
                    index = raw_end + 3
                    state = "raw_multiline_string"
                elif raw_end < len(characters) and characters[raw_end] == '\"':
                    characters[index : raw_end + 1] = [" "] * (raw_hashes + 1)
                    index = raw_end + 1
                    state = "raw_string"
                else:
                    index += 1
            elif source.startswith('\"\"\"', index):
                characters[index : index + 3] = [" "] * 3
                index += 3
                state = "multiline_string"
            elif characters[index] == '\"':
                characters[index] = " "
                index += 1
                state = "string"
            else:
                index += 1
        elif state == "line_comment":
            if characters[index] == "\n":
                state = "code"
            else:
                characters[index] = " "
            index += 1
        elif state == "block_comment":
            if source.startswith("/*", index):
                characters[index : index + 2] = [" "] * 2
                index += 2
                block_depth += 1
            elif source.startswith("*/", index):
                characters[index : index + 2] = [" "] * 2
                index += 2
                block_depth -= 1
                if block_depth == 0:
                    state = "code"
            else:
                if characters[index] != "\n":
                    characters[index] = " "
                index += 1
        elif state == "string":
            if characters[index] == "\\":
                characters[index] = " "
                if index + 1 < len(characters) and characters[index + 1] != "\n":
                    characters[index + 1] = " "
                    index += 2
                else:
                    index += 1
            elif characters[index] == '\"':
                characters[index] = " "
                index += 1
                state = "code"
            else:
                if characters[index] != "\n":
                    characters[index] = " "
                index += 1
        elif state == "raw_string":
            delimiter = '\"' + "#" * raw_hashes
            if source.startswith(delimiter, index):
                characters[index : index + len(delimiter)] = [" "] * len(delimiter)
                index += len(delimiter)
                state = "code"
            else:
                if characters[index] != "\n":
                    characters[index] = " "
                index += 1
        elif state == "raw_multiline_string":
            delimiter = '\"\"\"' + "#" * raw_hashes
            if source.startswith(delimiter, index):
                characters[index : index + len(delimiter)] = [" "] * len(delimiter)
                index += len(delimiter)
                state = "code"
            else:
                if characters[index] != "\n":
                    characters[index] = " "
                index += 1
        elif source.startswith('\"\"\"', index):
            characters[index : index + 3] = [" "] * 3
            index += 3
            state = "code"
        else:
            if characters[index] != "\n":
                characters[index] = " "
            index += 1
    return "".join(characters)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def declaration_span(
    source: str, masked: str, match: re.Match[str]
) -> tuple[int, int, int] | None:
    index = match.end()
    parentheses = 0
    brackets = 0
    opening = None
    while index < len(masked):
        character = masked[index]
        if character == "(":
            parentheses += 1
        elif character == ")":
            parentheses = max(0, parentheses - 1)
        elif character == "[":
            brackets += 1
        elif character == "]":
            brackets = max(0, brackets - 1)
        elif character == "{" and parentheses == 0 and brackets == 0:
            opening = index
            break
        elif character == "}" and parentheses == 0 and brackets == 0:
            # Protocol requirements and declarations without an implementation
            # have no body to measure. Do not attach them to the next type.
            return None
        index += 1
    if opening is None:
        return None
    depth = 1
    index = opening + 1
    while index < len(masked) and depth:
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
        index += 1
    if depth:
        return None
    return (
        line_number(source, match.start()),
        line_number(source, opening),
        line_number(source, index - 1),
    )


def swift_sources() -> list[Path]:
    return sorted((ROOT / "App").rglob("*.swift")) + sorted(
        (ROOT / "Sources").rglob("*.swift")
    )


def validate() -> list[str]:
    violations: list[str] = []
    for path in swift_sources():
        source = path.read_text(encoding="utf-8")
        relative = path.relative_to(ROOT)
        file_lines = len(source.splitlines())
        if file_lines > MAX_FILE_LINES:
            violations.append(
                f"{relative}:1 file has {file_lines} lines; limit is "
                f"{MAX_FILE_LINES}"
            )
        masked = mask_swift(source)
        declarations = (
            ("type", TYPE_PATTERN, MAX_TYPE_BODY_LINES),
            ("function", FUNCTION_PATTERN, MAX_FUNCTION_BODY_LINES),
        )
        for kind, pattern, limit in declarations:
            for match in pattern.finditer(masked):
                span = declaration_span(source, masked, match)
                if span is None:
                    continue
                body_lines = span[2] - span[1] - 1
                if body_lines <= limit:
                    continue
                name = (
                    match.group(2)
                    if kind == "type"
                    else match.group(2) or match.group(1).split()[0]
                )
                violations.append(
                    f"{relative}:{span[0]} {kind} {name} has "
                    f"{body_lines} body lines; limit is {limit}"
                )
    return violations


def main() -> int:
    violations = validate()
    if violations:
        for violation in violations:
            print(f"error: {violation}", file=sys.stderr)
        return 1
    print(
        "Validated Swift structure limits: "
        f"file <= {MAX_FILE_LINES}, type body <= {MAX_TYPE_BODY_LINES}, "
        f"function body <= {MAX_FUNCTION_BODY_LINES} lines"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
