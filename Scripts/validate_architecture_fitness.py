#!/usr/bin/env python3
"""Enforce reviewed architecture and source-safety boundaries.

The checks in this file intentionally describe narrow, reviewable seams. A new
dependency, color token, force unwrap, or Foundation Models output shape must
be added to the relevant declaration below instead of silently broadening a
regex exception.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_LANGUAGES = ("en", "zh-Hans")
CORE_ALLOWED_IMPORTS = {"Foundation", "CryptoKit"}
REVIEWED_CORE_IMPORTS = {
    "Sources/MoneyUpCore/PerformanceSignposts.swift": {"OSLog"},
}
REVIEWED_CORE_CRYPTOKIT = {
    "Sources/MoneyUpCore/TransactionCSVRowParser.swift": "SHA256",
}
REVIEWED_COLORSETS = {
    "App/MoneyUp/Assets.xcassets/AccentColor.colorset": (
        "#34785F",
        "#82CEAE",
    ),
    "App/MoneyUp/Assets.xcassets/BrandAction.colorset": (
        "#34785F",
        "#34785F",
    ),
    "App/MoneyUp/Assets.xcassets/BrandBackground.colorset": (
        "#F7F9F6",
        "#101512",
    ),
    "App/MoneyUp/Assets.xcassets/BrandMist.colorset": (
        "#D4EAD8",
        "#3C6349",
    ),
    "App/MoneyUp/Assets.xcassets/BrandSurface.colorset": (
        "#EEF4F0",
        "#18211D",
    ),
    "App/MoneyUp/Assets.xcassets/BrandSurfaceElevated.colorset": (
        "#FAFBF9",
        "#202923",
    ),
}

IMPORT_PATTERN = re.compile(
    r"(?m)^[ \t]*"
    r"(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*\))?[ \t]+)*"
    r"(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"
    r"import(?:[ \t]+(?:class|enum|func|protocol|struct|typealias|var))?"
    r"[ \t]+([A-Za-z_][A-Za-z0-9_]*|`[A-Za-z_][A-Za-z0-9_]*`)"
)
TYPE_PATTERN = re.compile(
    r"\b(struct|class|enum|actor|protocol|extension)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)"
    r"(?P<header>[^{};]*?)\{",
    re.DOTALL,
)
LOCALIZED_DECLARATION_PATTERN = re.compile(
    r"(?:"
    r"\bvar\s+[A-Za-z_][A-Za-z0-9_]*[^{};]*:\s*"
    r"(?:\[\s*)?LocalizedString(?:Key|Resource)\b|"
    r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*[^{};]*->\s*"
    r"(?:\[\s*)?LocalizedString(?:Key|Resource)\b"
    r")[^{};]*\{",
    re.DOTALL,
)
LOCALIZED_BINDING_PATTERN = re.compile(
    r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*"
    r"(?P<type>[^=;\n]*\bLocalizedString(?:Key|Resource)\b[^=;\n]*)=",
)
LOCALIZATION_KEY_PATTERN = re.compile(
    r"[a-z][a-z0-9]*(?:[._-][a-z0-9_]+)+"
)
LOCALIZED_CALL_PREFIX = re.compile(
    r"(?:"
    r"\bString\s*\(\s*localized\s*:|"
    r"\bAppLocalization\s*\.\s*string\s*\(|"
    r"\bLocalizedString(?:Key|Resource)\s*\(|"
    r"\b(?:Text|Button|Label|Picker|Toggle|SecureField|TextField|Section|"
    r"NavigationLink|DisclosureGroup|LabeledContent|Menu|GroupBox|Gauge|"
    r"ContentUnavailableView|ProgressView|DatePicker|Link|ShareLink|"
    r"confirmationDialog|alert)\s*\(|"
    r"\.(?:navigationTitle|accessibilityLabel|accessibilityHint|"
    r"accessibilityValue|help)\s*\(|"
    r"\.searchable\s*\([^)]*\bprompt\s*:"
    r")\s*$",
    re.DOTALL,
)
OFFLINE_FORBIDDEN_IMPORTS = {
    "CFNetwork",
    "Darwin",
    "FoundationNetworking",
    "Glibc",
    "Network",
    "WebKit",
}
OFFLINE_FORBIDDEN_SYMBOLS = (
    "URLSession",
    "NSURLConnection",
    "NWConnection",
    "NWListener",
    "NWPathMonitor",
    "CFReadStreamCreateForHTTPRequest",
    "CFWriteStream",
    "CFSocket",
    "WKWebView",
    "Alamofire",
    "Moya",
)
RAW_SOCKET_CALL_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_.])(?:socket|connect|send|recv|getaddrinfo)\s*\(|"
    r"\b(?:Darwin|Glibc)\s*\.\s*"
    r"(?:socket|connect|send|recv|getaddrinfo)\s*\("
)
URL_LOADING_CONSTRUCTOR_PATTERN = re.compile(
    r"\b(?:Data|String)\s*\(\s*contentsOf\s*:"
)
W3_FORBIDDEN_TYPES = {
    "BudgetNode",
    "CurrencyCode",
    "Date",
    "Decimal",
    "JournalEntry",
    "LedgerAccount",
    "Money",
    "Posting",
    "UUID",
}
W3_FORBIDDEN_FIELD_TOKENS = {
    "account",
    "amount",
    "balance",
    "category",
    "currency",
    "note",
    "payee",
    "transaction",
}
W3_INT_FIELD_TOKENS = {
    "choice",
    "id",
    "identifier",
    "index",
    "ordinal",
    "rank",
    "template",
}
W3_FORBIDDEN_API_PARTS = {
    "adapter",
    "package",
    "packages",
    "pcc",
    "provider",
    "tool",
    "tools",
}
W3_FORBIDDEN_API_PATTERNS = (
    re.compile(r"\bPrivateCloudCompute[A-Za-z0-9_]*\b"),
    re.compile(r"\bSystemLanguageModel\s*\("),
    re.compile(r"\buseCase\s*:"),
    re.compile(
        r"\bSystemLanguageModel\b[^=\n;]*=\s*\.\s*init\s*\(",
    ),
    re.compile(
        r"\bLanguageModelSession\s*\([^)]*\bmodel\s*:",
        re.DOTALL,
    ),
    re.compile(
        r"\bLanguageModelSession\b[^=\n;]*=\s*\.\s*init\s*\("
        r"[^)]*\bmodel\s*:",
        re.DOTALL,
    ),
)
W3_FRAMEWORK_USE_PATTERN = re.compile(
    r"@(?:Generable|Guide)\b|"
    r"\b(?:SystemLanguageModel|LanguageModelSession|GeneratedContent|"
    r"GenerationGuide|GenerationOptions|GenerationSchema|"
    r"DynamicGenerationSchema|Instructions|Prompt|Transcript|Tool|"
    r"ToolChoice)\b|"
    r"\b(?:respond|streamResponse)\s*\("
)
W3_IOS_26_AVAILABILITY = re.compile(
    r"@available\s*\(\s*iOS\s+26(?:\.0)?\s*,[^)]*\)"
)


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str
    detail: str

    def render(self) -> str:
        return f"{self.path}:{self.line} [{self.rule}] {self.detail}"


@dataclass(frozen=True)
class StringLiteral:
    start: int
    end: int
    value: str


@dataclass(frozen=True)
class SwiftScan:
    source: str
    masked: str
    strings: tuple[StringLiteral, ...]


@dataclass(frozen=True)
class TypeDeclaration:
    kind: str
    name: str
    header: str
    start: int
    opening: int
    closing: int
    generable: bool


@dataclass(frozen=True)
class PropertyDeclaration:
    name: str
    type_name: str | None
    attributes: str
    offset: int


@dataclass(frozen=True)
class SafeException:
    path: str
    kind: str
    snippet: str
    expected_count: int
    reason: str


# These are total initializers over fixed literals or mathematically bounded
# values. Exact snippets and occurrence counts keep the exceptions reviewable;
# changing the expression makes the allowlist stale and fails validation.
SAFE_EXCEPTIONS = (
    SafeException(
        path="Sources/MoneyUpCore/CheckedDecimal.swift",
        kind="force-unwrap",
        snippet=(
            'private static let maximumMagnitude = Decimal(\n'
            '        string: "9e127",\n'
            '        locale: Locale(identifier: "en_US_POSIX")\n'
            "    )!"
        ),
        expected_count=1,
        reason="the fixed POSIX decimal literal is valid by construction",
    ),
    SafeException(
        path="Sources/MoneyUpCore/FinancialPeriodBoundary.swift",
        kind="force-unwrap",
        snippet="TimeZone(secondsFromGMT: 0)!",
        expected_count=1,
        reason="Foundation defines the zero-offset time zone",
    ),
    SafeException(
        path="Sources/MoneyUpCore/LedgerPortability.swift",
        kind="force-unwrap",
        snippet="calendar.timeZone = TimeZone(secondsFromGMT: 0)!",
        expected_count=2,
        reason="Foundation defines the zero-offset time zone",
    ),
    SafeException(
        path="Sources/MoneyUpCore/LedgerXLSXExporter.swift",
        kind="force-unwrap",
        snippet="Character(UnicodeScalar(65 + value % 26)!)",
        expected_count=1,
        reason="the modulo expression is always an ASCII A-through-Z scalar",
    ),
    SafeException(
        path="App/MoneyUp/DatabaseKeyStore.swift",
        kind="force-unwrap",
        snippet="SecRandomCopyBytes(kSecRandomDefault, keyLength, bytes.baseAddress!)",
        expected_count=1,
        reason="the mutable buffer belongs to a fixed, nonempty key Data value",
    ),
    SafeException(
        path="App/MoneyUp/LockedCaptureStore.swift",
        kind="force-unwrap",
        snippet="SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)",
        expected_count=1,
        reason="the mutable buffer belongs to a fixed 32-byte Data value",
    ),
    SafeException(
        path="App/MoneyUp/InsightsAnalysis.swift",
        kind="force-unwrap",
        snippet='Decimal(string: "0.005")!',
        expected_count=1,
        reason="the fixed decimal threshold literal is valid by construction",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/expense")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/income")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/transfer")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/refund")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/smart-entry")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/MoneyUpWidget/MoneyUpWidget.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/scan-receipt")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
)

# Version-one archive compatibility is reached only after FileHandle has
# opened and bounded the same source URL. Keep this one legacy mapped read an
# exact, counted exception; all new contentsOf: URL loads fail closed.
REVIEWED_LOCAL_URL_LOADS = (
    SafeException(
        path="Sources/MoneyUpPersistence/PortableArchiveV2.swift",
        kind="local-url-load",
        snippet="Data(contentsOf: sourceURL, options: [.mappedIfSafe])",
        expected_count=1,
        reason="the source was already opened and bounded as a local archive file",
    ),
)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def relative_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def swift_sources(root: Path) -> list[Path]:
    result: list[Path] = []
    for directory in (root / "App", root / "Sources"):
        if directory.is_dir():
            result.extend(directory.rglob("*.swift"))
    return sorted(result)


def _mask_range(characters: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if characters[index] != "\n":
            characters[index] = " "


def _string_delimiter(source: str, index: int) -> tuple[int, str] | None:
    hashes = 0
    while index + hashes < len(source) and source[index + hashes] == "#":
        hashes += 1
    quote = index + hashes
    if source.startswith('"""', quote):
        return hashes, '"""'
    if quote < len(source) and source[quote] == '"':
        return hashes, '"'
    return None


def _consume_string(
    source: str,
    start: int,
    hashes: int,
    quote: str,
) -> tuple[int, str, tuple[tuple[int, int], ...]]:
    content_start = start + hashes + len(quote)
    closing = quote + "#" * hashes
    interpolation = "\\" + "#" * hashes + "("
    interpolations: list[tuple[int, int]] = []
    index = content_start
    while index < len(source):
        if source.startswith(closing, index):
            return (
                index + len(closing),
                source[content_start:index],
                tuple(interpolations),
            )
        if source.startswith(interpolation, index):
            opening = index + len(interpolation) - 1
            expression_end = _consume_parenthesized(source, opening)
            interpolations.append((opening + 1, expression_end))
            index = min(len(source), expression_end + 1)
        elif hashes == 0 and source[index] == "\\":
            index = min(len(source), index + 2)
        else:
            index += 1
    return len(source), source[content_start:], tuple(interpolations)


def _consume_parenthesized(source: str, opening: int) -> int:
    """Return the closing parenthesis for a Swift interpolation expression."""
    depth = 1
    index = opening + 1
    while index < len(source):
        if source.startswith("//", index):
            line_end = source.find("\n", index + 2)
            index = len(source) if line_end == -1 else line_end
            continue
        if source.startswith("/*", index):
            comment_depth = 1
            index += 2
            while index < len(source) and comment_depth:
                if source.startswith("/*", index):
                    comment_depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    comment_depth -= 1
                    index += 2
                else:
                    index += 1
            continue
        delimiter = _string_delimiter(source, index)
        if delimiter is not None:
            index, _, _ = _consume_string(source, index, *delimiter)
            continue
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return len(source)


def scan_swift(source: str) -> SwiftScan:
    """Mask comments and strings while retaining static string spans."""
    characters = list(source)
    strings: list[StringLiteral] = []
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            if end == -1:
                end = len(source)
            _mask_range(characters, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < len(source) and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            _mask_range(characters, index, end)
            index = end
            continue
        delimiter = _string_delimiter(source, index)
        if delimiter is not None:
            end, value, interpolations = _consume_string(source, index, *delimiter)
            strings.append(StringLiteral(index, end, value))
            _mask_range(characters, index, end)
            for expression_start, expression_end in interpolations:
                nested = scan_swift(source[expression_start:expression_end])
                characters[expression_start:expression_end] = list(nested.masked)
                strings.extend(
                    StringLiteral(
                        expression_start + literal.start,
                        expression_start + literal.end,
                        literal.value,
                    )
                    for literal in nested.strings
                )
            index = end
            continue
        index += 1
    return SwiftScan(source, "".join(characters), tuple(strings))


def find_matching(
    masked: str,
    opening: int,
    open_character: str = "{",
    close_character: str = "}",
) -> int | None:
    depth = 1
    index = opening + 1
    while index < len(masked):
        if masked[index] == open_character:
            depth += 1
        elif masked[index] == close_character:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def type_declarations(scan: SwiftScan) -> list[TypeDeclaration]:
    declarations: list[TypeDeclaration] = []
    for match in TYPE_PATTERN.finditer(scan.masked):
        opening = match.end() - 1
        closing = find_matching(scan.masked, opening)
        if closing is None:
            continue
        prefix_start = max(
            scan.masked.rfind("}", 0, match.start()),
            scan.masked.rfind(";", 0, match.start()),
        )
        prefix = scan.masked[prefix_start + 1:match.start()]
        generable = re.search(r"@Generable\b[^{};]*$", prefix) is not None
        declarations.append(
            TypeDeclaration(
                kind=match.group(1),
                name=match.group(2),
                header=match.group("header"),
                start=match.start(),
                opening=opening,
                closing=closing,
                generable=generable,
            )
        )
    return declarations


def import_modules(scan: SwiftScan) -> list[tuple[str, int]]:
    return [
        (match.group(1).strip("`"), match.start(1))
        for match in IMPORT_PATTERN.finditer(scan.masked)
    ]


def validate_core_imports(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    core = root / "Sources" / "MoneyUpCore"
    if not core.is_dir():
        return violations
    for path in sorted(core.rglob("*.swift")):
        relative = relative_path(path, root)
        scan = scan_swift(path.read_text(encoding="utf-8"))
        modules = import_modules(scan)
        for module, offset in modules:
            reviewed_modules = REVIEWED_CORE_IMPORTS.get(relative, set())
            if module not in CORE_ALLOWED_IMPORTS | reviewed_modules:
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, offset),
                        "core-import",
                        f"MoneyUpCore may not import {module}",
                    )
                )
            if module == "CryptoKit" and relative not in REVIEWED_CORE_CRYPTOKIT:
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, offset),
                        "core-cryptokit",
                        "CryptoKit is reviewed only for the CSV SHA-256 fingerprint",
                    )
                )
        if "OSLog" in REVIEWED_CORE_IMPORTS.get(relative, set()):
            plain_oslog_imports = list(re.finditer(
                r"(?m)^[ \t]*import[ \t]+OSLog[ \t]*$",
                scan.masked,
            ))
            oslog_import_count = sum(
                module == "OSLog" for module, _ in modules
            )
            if len(plain_oslog_imports) != 1 or oslog_import_count != 1:
                violations.append(
                    Violation(
                        relative,
                        1,
                        "core-oslog",
                        "OSLog must use one plain, non-exported import at the "
                        "reviewed performance-signpost seam",
                    )
                )
        if relative not in REVIEWED_CORE_CRYPTOKIT:
            continue
        if "CryptoKit" not in {module for module, _ in modules}:
            violations.append(
                Violation(relative, 1, "core-cryptokit", "reviewed CryptoKit import is missing")
            )
            continue
        selective_imports = list(re.finditer(
            r"(?m)^[ \t]*import[ \t]+struct[ \t]+CryptoKit\.SHA256[ \t]*$",
            scan.masked,
        ))
        cryptokit_import_count = sum(
            module == "CryptoKit" for module, _ in modules
        )
        if len(selective_imports) != 1 or cryptokit_import_count != 1:
            violations.append(
                Violation(
                    relative,
                    1,
                    "core-cryptokit",
                    "CryptoKit must use the selective import struct CryptoKit.SHA256",
                )
            )
        reviewed_symbol = REVIEWED_CORE_CRYPTOKIT[relative]
        code = list(scan.masked)
        for match in IMPORT_PATTERN.finditer(scan.masked):
            line_end = scan.masked.find("\n", match.end())
            if line_end == -1:
                line_end = len(scan.masked)
            _mask_range(code, match.start(), line_end)
        code_without_imports = "".join(code)
        uses = list(re.finditer(rf"\b{reviewed_symbol}\b", code_without_imports))
        if not uses:
            violations.append(
                Violation(relative, 1, "core-cryptokit", "reviewed SHA-256 use is missing")
            )
        for use in uses:
            tail = code_without_imports[use.end():]
            if re.match(r"\s*\.\s*hash\s*\(\s*data\s*:", tail) is None:
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, use.start()),
                        "core-cryptokit",
                        "CryptoKit is limited to SHA256.hash(data:)",
                    )
                )
    return violations


def _inherited_type_names(header: str) -> set[str]:
    header = re.split(r"\bwhere\b", header, maxsplit=1)[0]
    depth = 0
    inheritance_start: int | None = None
    for index, character in enumerate(header):
        if character in "<([":
            depth += 1
        elif character in ">)]" and depth:
            depth -= 1
        elif character == ":" and depth == 0:
            inheritance_start = index + 1
            break
    if inheritance_start is None:
        return set()
    inheritance = header[inheritance_start:]
    components: list[str] = []
    depth = 0
    component_start = 0
    for index, character in enumerate(inheritance):
        if character in "<([":
            depth += 1
        elif character in ">)]" and depth:
            depth -= 1
        elif character in ",&" and depth == 0:
            components.append(inheritance[component_start:index])
            component_start = index + 1
    components.append(inheritance[component_start:])
    names: set[str] = set()
    for component in components:
        match = re.match(
            r"\s*(?:any\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)",
            component,
        )
        if match is not None:
            names.add(match.group(1).split(".")[-1])
    return names


def _is_view_header(header: str) -> bool:
    return "View" in _inherited_type_names(header)


def validate_view_posting_boundary(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    scans = {
        path: scan_swift(path.read_text(encoding="utf-8"))
        for path in swift_sources(root)
    }
    declarations = {
        path: type_declarations(scan) for path, scan in scans.items()
    }
    inheritance: dict[str, set[str]] = {}
    for values in declarations.values():
        for declaration in values:
            inheritance.setdefault(declaration.name.split(".")[-1], set()).update(
                _inherited_type_names(declaration.header)
            )
    view_names = {"View"} | {
        name for name, inherited in inheritance.items() if "View" in inherited
    }
    changed = True
    while changed:
        changed = False
        for name, inherited in inheritance.items():
            if name not in view_names and inherited & view_names:
                view_names.add(name)
                changed = True
    for path, values in declarations.items():
        scan = scans[path]
        relative = relative_path(path, root)
        for declaration in values:
            if (
                declaration.name.split(".")[-1] not in view_names
                and not _is_view_header(declaration.header)
            ):
                continue
            body = scan.masked[declaration.opening + 1:declaration.closing]
            for match in re.finditer(r"\bTransactionFactory\s*\.", body):
                offset = declaration.opening + 1 + match.start()
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, offset),
                        "view-posting",
                        f"SwiftUI view {declaration.name} constructs a posting; "
                        "route through AppModel",
                    )
                )
    return violations


def _component_byte(value: object) -> int:
    if not isinstance(value, str):
        raise ValueError("component is not a string")
    if value.lower().startswith("0x"):
        result = int(value, 16)
    else:
        result = round(float(value) * 255)
    if not 0 <= result <= 255:
        raise ValueError("component is outside sRGB")
    return result


def _colorset_values(payload: object) -> tuple[str, str]:
    if not isinstance(payload, dict) or not isinstance(payload.get("colors"), list):
        raise ValueError("colors must be an array")
    slots: dict[str, str] = {}
    for item in payload["colors"]:
        if not isinstance(item, dict) or item.get("idiom") != "universal":
            raise ValueError("each color must use the universal idiom")
        appearances = item.get("appearances", [])
        if appearances == []:
            slot = "light"
        elif appearances == [{"appearance": "luminosity", "value": "dark"}]:
            slot = "dark"
        else:
            raise ValueError("only universal light and dark slots are reviewed")
        color = item.get("color")
        if not isinstance(color, dict) or color.get("color-space") != "srgb":
            raise ValueError("colors must use explicit sRGB")
        components = color.get("components")
        if not isinstance(components, dict):
            raise ValueError("color components are missing")
        if abs(float(components.get("alpha", "nan")) - 1.0) > 0.0001:
            raise ValueError("colors must be opaque")
        red = _component_byte(components.get("red"))
        green = _component_byte(components.get("green"))
        blue = _component_byte(components.get("blue"))
        if slot in slots:
            raise ValueError(f"duplicate {slot} slot")
        slots[slot] = f"#{red:02X}{green:02X}{blue:02X}"
    if set(slots) != {"light", "dark"}:
        raise ValueError("both light and dark slots are required")
    return slots["light"], slots["dark"]


def validate_colorsets(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    discovered = {
        relative_path(path, root)
        for path in (root / "App").rglob("*.colorset")
        if path.is_dir()
    } if (root / "App").is_dir() else set()
    reviewed = set(REVIEWED_COLORSETS)
    for undeclared in sorted(discovered - reviewed):
        violations.append(
            Violation(
                undeclared,
                1,
                "colorset-registry",
                "colorset is not declared in REVIEWED_COLORSETS",
            )
        )
    for missing in sorted(reviewed - discovered):
        violations.append(
            Violation(missing, 1, "colorset-registry", "reviewed colorset is missing")
        )
    for relative in sorted(discovered & reviewed):
        contents = root / relative / "Contents.json"
        try:
            payload = json.loads(contents.read_text(encoding="utf-8"))
            actual = _colorset_values(payload)
        except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
            violations.append(
                Violation(relative, 1, "colorset-payload", f"invalid Contents.json: {error}")
            )
            continue
        if actual != REVIEWED_COLORSETS[relative]:
            violations.append(
                Violation(
                    relative,
                    1,
                    "colorset-palette",
                    f"expected {REVIEWED_COLORSETS[relative]}, found {actual}",
                )
            )
    return violations


def _string_units(payload: object, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], object]:
    units: dict[tuple[str, ...], object] = {}
    if isinstance(payload, dict):
        if "stringUnit" in payload:
            units[path] = payload["stringUnit"]
        for key, value in payload.items():
            if key != "stringUnit" and isinstance(value, (dict, list)):
                units.update(_string_units(value, (*path, str(key))))
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            if isinstance(value, (dict, list)):
                units.update(_string_units(value, (*path, str(index))))
    return units


def _catalog(
    root: Path,
    relative: str,
) -> tuple[set[str], list[Violation]]:
    violations: list[Violation] = []
    path = root / relative
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return set(), [Violation(relative, 1, "localization-catalog", str(error))]
    strings = payload.get("strings") if isinstance(payload, dict) else None
    if not isinstance(strings, dict):
        return set(), [
            Violation(relative, 1, "localization-catalog", "strings dictionary is missing")
        ]
    for key, entry in strings.items():
        localizations = entry.get("localizations") if isinstance(entry, dict) else None
        if not isinstance(localizations, dict):
            violations.append(
                Violation(relative, 1, "localization-bilingual", f"{key} has no localizations")
            )
            continue
        expected_paths: set[tuple[str, ...]] | None = None
        for language in REQUIRED_LANGUAGES:
            units = _string_units(localizations.get(language))
            if not units:
                violations.append(
                    Violation(
                        relative,
                        1,
                        "localization-bilingual",
                        f"{key} has no complete {language} string unit",
                    )
                )
                continue
            if expected_paths is None:
                expected_paths = set(units)
            elif set(units) != expected_paths:
                violations.append(
                    Violation(
                        relative,
                        1,
                        "localization-bilingual",
                        f"{key} has mismatched {language} variations",
                    )
                )
            for unit in units.values():
                if (
                    not isinstance(unit, dict)
                    or unit.get("state") != "translated"
                    or not isinstance(unit.get("value"), str)
                    or not unit["value"].strip()
                ):
                    violations.append(
                        Violation(
                            relative,
                            1,
                            "localization-bilingual",
                            f"{key} has an incomplete {language} value",
                        )
                    )
                    break
    return set(strings), violations


def _localized_keys(scan: SwiftScan) -> set[tuple[str, int]]:
    keys: set[tuple[str, int]] = set()
    for literal in scan.strings:
        if LOCALIZATION_KEY_PATTERN.fullmatch(literal.value) is None:
            continue
        prefix = scan.masked[max(0, literal.start - 240):literal.start]
        if LOCALIZED_CALL_PREFIX.search(prefix):
            keys.add((literal.value, literal.start))
    for match in LOCALIZED_DECLARATION_PATTERN.finditer(scan.masked):
        opening = match.end() - 1
        closing = find_matching(scan.masked, opening)
        if closing is None:
            continue
        for literal in scan.strings:
            if (
                opening < literal.start < closing
                and LOCALIZATION_KEY_PATTERN.fullmatch(literal.value)
            ):
                keys.add((literal.value, literal.start))
    for match in LOCALIZED_BINDING_PATTERN.finditer(scan.masked):
        value_start = match.end()
        while value_start < len(scan.masked) and scan.masked[value_start].isspace():
            value_start += 1
        opening = scan.masked[value_start] if value_start < len(scan.masked) else ""
        closing_character = {"[": "]", "(": ")", "{": "}"}.get(opening)
        if closing_character is None:
            value_end = scan.masked.find("\n", value_start)
            if value_end == -1:
                value_end = len(scan.masked)
        else:
            matched = find_matching(
                scan.masked, value_start, opening, closing_character
            )
            value_end = len(scan.masked) if matched is None else matched
        type_name = match.group("type")
        dictionary = type_name.strip().startswith("[") and ":" in type_name
        key_type, value_type = type_name, type_name
        if dictionary:
            inner = type_name.strip()[1:-1]
            key_type, value_type = inner.split(":", 1)
        localized_key = "LocalizedString" in key_type
        localized_value = "LocalizedString" in value_type
        for literal in scan.strings:
            if not (
                value_start < literal.start < value_end
                and LOCALIZATION_KEY_PATTERN.fullmatch(literal.value)
            ):
                continue
            if not dictionary:
                keys.add((literal.value, literal.start))
                continue
            element_start = max(
                value_start,
                scan.masked.rfind(",", value_start, literal.start) + 1,
            )
            is_value = ":" in scan.masked[element_start:literal.start]
            if (is_value and localized_value) or (not is_value and localized_key):
                keys.add((literal.value, literal.start))
    for literal in scan.strings:
        if LOCALIZATION_KEY_PATTERN.fullmatch(literal.value) is None:
            continue
        line_start = scan.masked.rfind("\n", 0, literal.start) + 1
        prefix = scan.masked[line_start:literal.start]
        if re.search(
            r"LocalizedString(?:Key|Resource)[^=]*=\s*[\[({]*\s*$",
            prefix,
        ):
            keys.add((literal.value, literal.start))
    return keys


def validate_static_localizations(root: Path) -> list[Violation]:
    app_catalog = "App/MoneyUp/Resources/Localizable.xcstrings"
    widget_catalog = "App/MoneyUpWidget/Localizable.xcstrings"
    app_keys, violations = _catalog(root, app_catalog)
    widget_keys, widget_violations = _catalog(root, widget_catalog)
    violations.extend(widget_violations)
    source_contract = (
        (root / "App" / "MoneyUp", ((app_keys, app_catalog),)),
        (
            root / "App" / "Shared",
            ((app_keys, app_catalog), (widget_keys, widget_catalog)),
        ),
        (root / "App" / "MoneyUpWidget", ((widget_keys, widget_catalog),)),
    )
    for directory, catalogs in source_contract:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            scan = scan_swift(source)
            for key, offset in sorted(_localized_keys(scan)):
                for catalog_keys, catalog_path in catalogs:
                    if key in catalog_keys:
                        continue
                    violations.append(
                        Violation(
                            relative_path(path, root),
                            line_number(source, offset),
                            "localization-key",
                            f"static user-visible key {key!r} is missing from {catalog_path}",
                        )
                    )
    return violations


def _reviewed_local_load_offsets(
    root: Path,
    exceptions: tuple[SafeException, ...],
) -> tuple[dict[str, set[int]], list[Violation]]:
    allowed: dict[str, set[int]] = {}
    violations: list[Violation] = []
    for exception in exceptions:
        path = root / exception.path
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        starts = [
            match.start()
            for match in re.finditer(re.escape(exception.snippet), source)
        ]
        if len(starts) != exception.expected_count:
            violations.append(
                Violation(
                    exception.path,
                    1,
                    "offline-local-load",
                    f"expected {exception.expected_count} exact occurrence(s) for: "
                    f"{exception.reason}",
                )
            )
            continue
        allowed.setdefault(exception.path, set()).update(starts)
    return allowed, violations


def _first_call_argument(masked: str, start: int, end: int) -> str:
    depths = {"(": 0, "[": 0, "{": 0}
    pairs = {")": "(", "]": "[", "}": "{"}
    for index in range(start, end):
        character = masked[index]
        if character in depths:
            depths[character] += 1
        elif character in pairs and depths[pairs[character]]:
            depths[pairs[character]] -= 1
        elif character == "," and not any(depths.values()):
            return masked[start:index].strip()
    return masked[start:end].strip()


def _is_statically_local_url(scan: SwiftScan, call_start: int, argument: str) -> bool:
    local_origin = re.compile(
        r"(?:URL\s*\(\s*fileURLWithPath\s*:|"
        r"FileManager\s*\.\s*default\s*\.\s*(?:temporaryDirectory|"
        r"homeDirectoryForCurrentUser)|"
        r"Bundle\s*\.\s*(?:main|module)\s*\.\s*url\s*\()"
    )
    if local_origin.match(argument):
        return True
    identifier = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)", argument)
    if identifier is None:
        return False
    name = identifier.group(1)
    prefix = scan.masked[:call_start]
    assignments = list(
        re.finditer(rf"\blet\s+{re.escape(name)}\s*=", prefix)
    )
    if not assignments:
        return False
    assigned_expression = prefix[assignments[-1].end():]
    return local_origin.match(assigned_expression.lstrip()) is not None


def validate_offline_boundary(
    root: Path,
    local_load_exceptions: tuple[SafeException, ...] = REVIEWED_LOCAL_URL_LOADS,
) -> list[Violation]:
    allowed_loads, violations = _reviewed_local_load_offsets(
        root, local_load_exceptions
    )
    for path in swift_sources(root):
        source = path.read_text(encoding="utf-8")
        scan = scan_swift(source)
        relative = relative_path(path, root)
        for module, offset in import_modules(scan):
            if module in OFFLINE_FORBIDDEN_IMPORTS:
                violations.append(
                    Violation(
                        relative,
                        line_number(source, offset),
                        "offline-boundary",
                        f"forbidden runtime import {module}",
                    )
                )
        for symbol in OFFLINE_FORBIDDEN_SYMBOLS:
            pattern = rf"\b{re.escape(symbol)}[A-Za-z0-9_]*\b"
            for match in re.finditer(pattern, scan.masked):
                violations.append(
                    Violation(
                        relative,
                        line_number(source, match.start()),
                        "offline-boundary",
                        f"forbidden runtime symbol {symbol}",
                    )
                )
        for match in RAW_SOCKET_CALL_PATTERN.finditer(scan.masked):
            violations.append(
                Violation(
                    relative,
                    line_number(source, match.start()),
                    "offline-boundary",
                    f"forbidden raw socket call {match.group(0).strip()}",
                )
            )
        for match in URL_LOADING_CONSTRUCTOR_PATTERN.finditer(scan.masked):
            opening = scan.masked.find("(", match.start())
            closing = find_matching(scan.masked, opening, "(", ")")
            if closing is None:
                continue
            argument = _first_call_argument(scan.masked, match.end(), closing)
            if (
                match.start() in allowed_loads.get(relative, set())
                or _is_statically_local_url(scan, match.start(), argument)
            ):
                continue
            violations.append(
                Violation(
                    relative,
                    line_number(source, match.start()),
                    "offline-url-load",
                    "Data/String contentsOf: requires a statically local file URL "
                    "or an exact reviewed local-file exception",
                )
            )
    return violations


def _identifier_tokens(identifier: str) -> set[str]:
    split = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", identifier)
    split = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", split)
    return {token.lower() for token in re.split(r"[^A-Za-z0-9]+", split) if token}


def _leading_attributes(
    masked: str,
    start: int,
    end: int,
) -> tuple[list[str], int]:
    attributes: list[str] = []
    offset = start
    while offset < end:
        while offset < end and masked[offset].isspace():
            offset += 1
        if offset >= end or masked[offset] != "@":
            break
        match = re.match(r"@[A-Za-z_][A-Za-z0-9_\.]*", masked[offset:end])
        if match is None:
            break
        attribute_end = offset + match.end()
        whitespace_end = attribute_end
        while whitespace_end < end and masked[whitespace_end].isspace():
            whitespace_end += 1
        if whitespace_end < end and masked[whitespace_end] == "(":
            closing = find_matching(masked, whitespace_end, "(", ")")
            if closing is None or closing >= end:
                attribute_end = end
            else:
                attribute_end = closing + 1
        attributes.append(masked[offset:attribute_end].strip())
        offset = attribute_end
    while offset < end and masked[offset].isspace():
        offset += 1
    return attributes, offset


def _properties(scan: SwiftScan, declaration: TypeDeclaration) -> list[PropertyDeclaration]:
    properties: list[PropertyDeclaration] = []
    depth = 1
    offset = declaration.opening + 1
    consumed_until = offset
    for line in scan.masked[offset:declaration.closing].splitlines(keepends=True):
        if depth == 1 and offset >= consumed_until:
            content_start = offset + len(line) - len(line.lstrip())
            attributes, property_start = _leading_attributes(
                scan.masked,
                content_start,
                declaration.closing,
            )
            property_end = scan.masked.find("\n", property_start)
            if property_end == -1 or property_end > declaration.closing:
                property_end = declaration.closing
            stripped = scan.masked[property_start:property_end].strip()
            if re.search(r":\s*$", stripped):
                continuation_end = scan.masked.find("\n", property_end + 1)
                if continuation_end == -1 or continuation_end > declaration.closing:
                    continuation_end = declaration.closing
                stripped += scan.masked[property_end:continuation_end]
                property_end = continuation_end
            match = re.match(
                r"(?:(?:(?:public|internal|private|fileprivate|package)"
                r"(?:\s*\(\s*set\s*\))?|static|class|nonisolated)\s+)*"
                r"(?:let|var)\s+"
                r"(`?[A-Za-z_][A-Za-z0-9_]*`?)"
                r"(?:\s*:\s*([^={;]+))?",
                stripped,
            )
            if match is not None:
                suffix = stripped[match.end():]
                is_computed = "{" in suffix and (
                    "=" not in suffix or suffix.index("{") < suffix.index("=")
                )
                if not is_computed:
                    raw_name = match.group(1)
                    name = raw_name.strip("`")
                    name_offset = property_start + match.start(1) + (
                        1 if raw_name.startswith("`") else 0
                    )
                    properties.append(
                        PropertyDeclaration(
                            name=name,
                            type_name=match.group(2).strip() if match.group(2) else None,
                            attributes="\n".join(attributes),
                            offset=name_offset,
                        )
                    )
            consumed_until = max(consumed_until, property_end)
        depth += line.count("{") - line.count("}")
        offset += len(line)
    return properties


def _contains_forbidden_type(type_name: str) -> str | None:
    for forbidden in sorted(W3_FORBIDDEN_TYPES | {"String", "Substring"}):
        if re.search(rf"\b{forbidden}\b", type_name):
            return forbidden
    return None


def _validate_w3_property(
    relative: str,
    scan: SwiftScan,
    declaration: TypeDeclaration,
    property_declaration: PropertyDeclaration,
    fixed_enums: set[str],
) -> list[Violation]:
    if not declaration.generable or declaration.kind == "enum":
        return []
    violations: list[Violation] = []
    line = line_number(scan.source, property_declaration.offset)
    tokens = _identifier_tokens(property_declaration.name)
    sensitive = sorted(tokens & W3_FORBIDDEN_FIELD_TOKENS)
    if sensitive:
        violations.append(
            Violation(
                relative,
                line,
                "w3-sensitive-output",
                f"Foundation Models property name contains {', '.join(sensitive)}",
            )
        )
    if property_declaration.type_name:
        forbidden_type = _contains_forbidden_type(property_declaration.type_name)
        if forbidden_type:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-sensitive-output",
                    f"Foundation Models property exposes {forbidden_type}",
                )
            )
        type_tokens = _identifier_tokens(property_declaration.type_name)
        sensitive_type_tokens = sorted(type_tokens & W3_FORBIDDEN_FIELD_TOKENS)
        if sensitive_type_tokens:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-sensitive-output",
                    "Foundation Models property type contains "
                    + ", ".join(sensitive_type_tokens),
                )
            )
    type_name = property_declaration.type_name or ""
    if type_name == "Int":
        bounded_name = bool(tokens & W3_INT_FIELD_TOKENS)
        guide = re.search(
            r"@Guide\s*\(\s*(?:description\s*:\s*[^,\n]+,\s*)?"
            r"\.range\s*\(\s*([0-9]{1,3})\s*"
            r"\.\.\.\s*([0-9]{1,3})\s*\)\s*\)",
            property_declaration.attributes,
        )
        bounded_guide = (
            guide is not None
            and 0 <= int(guide.group(1)) <= int(guide.group(2)) <= 255
        )
        if not bounded_name or not bounded_guide:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-output-shape",
                    "generated Int must be an ordinal/template identifier with "
                    "a literal closed @Guide range within 0...255",
                )
            )
    elif type_name not in fixed_enums:
        violations.append(
            Violation(
                relative,
                line,
                "w3-output-shape",
                "generated fields may contain only bounded Int ordinals or local @Generable enums",
            )
        )
    return violations


def _validate_w3_enum(
    relative: str,
    scan: SwiftScan,
    declaration: TypeDeclaration,
) -> list[Violation]:
    if declaration.kind != "enum" or not declaration.generable:
        return []
    violations: list[Violation] = []
    cases: list[tuple[str, int]] = []
    depth = 1
    offset = declaration.opening + 1
    for line in scan.masked[offset:declaration.closing].splitlines(keepends=True):
        stripped = line.strip()
        if depth == 1:
            match = re.match(r"(?:indirect\s+)?case\s+(.+)", stripped)
            if match is not None:
                cases.append((match.group(1), offset + line.find("case")))
            elif re.search(r"\bcase\b", stripped):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, offset + line.find("case")),
                        "w3-output-shape",
                        "local @Generable enum contains unreviewed case syntax",
                    )
                )
        depth += line.count("{") - line.count("}")
        offset += len(line)
    if not cases:
        violations.append(
            Violation(
                relative,
                line_number(scan.source, declaration.start),
                "w3-output-shape",
                "local @Generable enum must declare fixed cases",
            )
        )
        return violations
    for case_declaration, case_offset in cases:
        case_line = line_number(scan.source, case_offset)
        if "(" in case_declaration:
            violations.append(
                Violation(
                    relative,
                    case_line,
                    "w3-output-shape",
                    "local @Generable enum cases may not carry associated values",
                )
            )
        identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", case_declaration)
        sensitive = sorted(
            set().union(*(_identifier_tokens(value) for value in identifiers))
            & W3_FORBIDDEN_FIELD_TOKENS
        ) if identifiers else []
        if sensitive:
            violations.append(
                Violation(
                    relative,
                    case_line,
                    "w3-sensitive-output",
                    "Foundation Models enum case contains " + ", ".join(sensitive),
                )
            )
    return violations


def _w3_generated_calls(
    relative: str,
    scan: SwiftScan,
    safe_types: set[str],
) -> list[Violation]:
    violations: list[Violation] = []
    for match in re.finditer(r"\b(?:respond|streamResponse)\s*\(", scan.masked):
        opening = scan.masked.find("(", match.start())
        closing = find_matching(scan.masked, opening, "(", ")")
        if closing is None:
            continue
        arguments = scan.masked[opening + 1:closing]
        generated = re.search(
            r"\bgenerating\s*:\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*\.self",
            arguments,
        )
        line = line_number(scan.source, match.start())
        if generated is None:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-string-output",
                    "Foundation Models responses must use a constrained generating: type",
                )
            )
            continue
        generated_type = generated.group(1).split(".")[-1]
        forbidden_type = _contains_forbidden_type(generated_type)
        sensitive_tokens = sorted(
            _identifier_tokens(generated_type) & W3_FORBIDDEN_FIELD_TOKENS
        )
        if forbidden_type:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-sensitive-output",
                    f"generated return type exposes {forbidden_type}",
                )
            )
        elif sensitive_tokens:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-sensitive-output",
                    "generated return type contains " + ", ".join(sensitive_tokens),
                )
            )
        elif generated_type not in safe_types:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-output-shape",
                    f"generated return type {generated_type} is not a "
                    "reviewed local @Generable type",
                )
            )
    return violations


def _can_import_foundation_models(condition: str) -> bool:
    compact = re.sub(r"\s+", "", condition)
    if "||" in compact or "!canImport(FoundationModels)" in compact:
        return False
    if re.search(r"!\(+canImport\(FoundationModels\)", compact):
        return False
    return "canImport(FoundationModels)" in compact


def _w3_compile_ranges(masked: str) -> list[tuple[int, int]]:
    """Return lines lexically inside the positive canImport branch."""
    ranges: list[tuple[int, int]] = []
    branches: list[bool] = []
    offset = 0
    for line in masked.splitlines(keepends=True):
        directive = re.match(r"^[ \t]*#(if|elseif|else|endif)\b(.*)$", line)
        if directive is None:
            if any(branches):
                if ranges and ranges[-1][1] == offset:
                    ranges[-1] = (ranges[-1][0], offset + len(line))
                else:
                    ranges.append((offset, offset + len(line)))
        elif directive.group(1) == "if":
            branches.append(_can_import_foundation_models(directive.group(2)))
        elif directive.group(1) == "elseif" and branches:
            branches[-1] = _can_import_foundation_models(directive.group(2))
        elif directive.group(1) == "else" and branches:
            branches[-1] = False
        elif directive.group(1) == "endif" and branches:
            branches.pop()
        offset += len(line)
    return ranges


def _w3_runtime_ranges(masked: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    declaration_header = re.compile(
        r"\s*(?:@[A-Za-z_][A-Za-z0-9_\.]*"
        r"(?:\([^{}]*\))?\s*)*"
        r"(?:(?:public|package|internal|fileprivate|private|final|indirect|"
        r"static|class|nonisolated|mutating|nonmutating|override|required|"
        r"convenience)\s+)*"
        r"(?:struct|class|enum|actor|protocol|extension|func|init|subscript)"
        r"\b[^{};]*\Z",
        re.DOTALL,
    )
    for marker in W3_IOS_26_AVAILABILITY.finditer(masked):
        opening = masked.find("{", marker.end())
        if opening == -1:
            continue
        header = masked[marker.end():opening]
        if (
            len(header) > 2_000
            or declaration_header.fullmatch(header) is None
        ):
            continue
        closing = find_matching(masked, opening)
        if closing is not None:
            range_start = marker.start()
            window_start = max(0, marker.start() - 2_000)
            candidates = [
                candidate.start()
                for candidate in re.finditer(
                    r"@[A-Za-z_][A-Za-z0-9_\.]*",
                    masked[window_start:marker.start() + 1],
                )
            ]
            for candidate in candidates:
                candidate += window_start
                if declaration_header.fullmatch(masked[candidate:opening]):
                    range_start = min(range_start, candidate)
            ranges.append((range_start, closing + 1))
    runtime_if = re.compile(
        r"\bif\s+#available\s*\(\s*iOS\s+26(?:\.0)?\s*,[^)]*\)\s*\{"
    )
    for marker in runtime_if.finditer(masked):
        opening = marker.end() - 1
        closing = find_matching(masked, opening)
        if closing is not None:
            ranges.append((marker.start(), closing + 1))
    return ranges


def _offset_in_ranges(offset: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start <= offset < end for start, end in ranges)


def _w3_forbidden_api_uses(masked: str) -> list[tuple[int, str]]:
    uses: dict[tuple[int, int], str] = {}
    for match in re.finditer(r"\b[A-Za-z_][A-Za-z0-9_]*\b", masked):
        if match.group(0) == "package" and re.match(
            r"\s*(?:\(\s*set\s*\))?\s+"
            r"(?:import|struct|class|enum|actor|protocol|extension|func|"
            r"init|subscript|let|var|typealias)\b",
            masked[match.end():],
        ):
            continue
        if _identifier_tokens(match.group(0)) & W3_FORBIDDEN_API_PARTS:
            uses[(match.start(), match.end())] = match.group(0)
    for pattern in W3_FORBIDDEN_API_PATTERNS:
        for match in pattern.finditer(masked):
            uses[(match.start(), match.end())] = match.group(0).strip()
    return [(start, uses[(start, end)]) for start, end in sorted(uses)]


def _strip_outer_parentheses(expression: str) -> str:
    result = expression.strip()
    while result.startswith("("):
        closing = find_matching(result, 0, "(", ")")
        if closing != len(result) - 1:
            break
        result = result[1:-1].strip()
    return result


def _top_level_conjuncts(condition: str) -> list[str]:
    expression = _strip_outer_parentheses(condition)
    conjuncts: list[str] = []
    depth = 0
    start = 0
    index = 0
    while index < len(expression):
        character = expression[index]
        if character in "([":
            depth += 1
        elif character in ")]" and depth:
            depth -= 1
        elif depth == 0 and character == ",":
            conjuncts.append(expression[start:index])
            start = index + 1
        elif depth == 0 and expression.startswith("&&", index):
            conjuncts.append(expression[start:index])
            start = index + 2
            index += 1
        index += 1
    conjuncts.append(expression[start:])
    return [_strip_outer_parentheses(value) for value in conjuncts]


def _guards_default_model_availability(condition: str) -> bool:
    availability = (
        r"\bSystemLanguageModel\s*\.\s*default\s*\.\s*availability\b"
    )
    direct = re.compile(
        availability + r"\s*==\s*\.\s*available\s*\Z"
    )
    pattern_case = re.compile(
        r"\bcase\s+\.\s*available\s*=\s*" + availability + r"\s*\Z"
    )
    return any(
        direct.fullmatch(conjunct) is not None
        or pattern_case.fullmatch(conjunct) is not None
        for conjunct in _top_level_conjuncts(condition)
    )


def _function_body_ranges(masked: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    declaration = re.compile(
        r"\b(?:func\s+[A-Za-z_][A-Za-z0-9_]*|init|subscript)\b"
        r"[^{};]*\{",
        re.DOTALL,
    )
    for match in declaration.finditer(masked):
        opening = match.end() - 1
        closing = find_matching(masked, opening)
        if closing is not None:
            ranges.append((opening, closing))
    return ranges


def _w3_model_availability_ranges(masked: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    conditional = re.compile(r"(?<!#)\bif\s+(?P<condition>[^{};]*)\{")
    for match in conditional.finditer(masked):
        if not _guards_default_model_availability(match.group("condition")):
            continue
        opening = match.end() - 1
        closing = find_matching(masked, opening)
        if closing is not None:
            ranges.append((opening + 1, closing))
    functions = _function_body_ranges(masked)
    guard = re.compile(
        r"\bguard\s+(?P<condition>[^{};]*?)\s+else\s*\{",
        re.DOTALL,
    )
    for match in guard.finditer(masked):
        if not _guards_default_model_availability(match.group("condition")):
            continue
        else_opening = match.end() - 1
        else_closing = find_matching(masked, else_opening)
        if else_closing is None or re.search(
            r"\b(?:return|throw)\b", masked[else_opening + 1:else_closing]
        ) is None:
            continue
        containers = [
            (opening, closing)
            for opening, closing in functions
            if opening < match.start() < closing
        ]
        if not containers:
            continue
        function_opening, function_closing = max(containers, key=lambda item: item[0])
        prefix = masked[function_opening + 1:match.start()]
        if prefix.count("{") != prefix.count("}"):
            continue
        ranges.append((else_closing + 1, function_closing))
    return ranges


def validate_w3_foundation_models(root: Path) -> list[Violation]:
    paths = swift_sources(root)
    scans = {
        path: scan_swift(path.read_text(encoding="utf-8")) for path in paths
    }
    importing = {
        path
        for path, scan in scans.items()
        if "FoundationModels" in {module for module, _ in import_modules(scan)}
    }
    if not importing:
        return []
    declarations = {path: type_declarations(scan) for path, scan in scans.items()}
    generable_paths = {
        path
        for path, values in declarations.items()
        if any(declaration.generable for declaration in values)
    }
    relevant = importing | generable_paths
    fixed_enums = {
        declaration.name
        for path in relevant
        for declaration in declarations[path]
        if declaration.kind == "enum" and declaration.generable
    }
    safe_types = {
        declaration.name
        for path in relevant
        for declaration in declarations[path]
        if declaration.generable
    }
    violations: list[Violation] = []
    compile_ranges = {
        path: _w3_compile_ranges(scan.masked) for path, scan in scans.items()
    }
    runtime_ranges = {
        path: _w3_runtime_ranges(scan.masked) for path, scan in scans.items()
    }
    model_availability_ranges = {
        path: _w3_model_availability_ranges(scan.masked)
        for path, scan in scans.items()
    }
    for path in sorted(importing):
        scan = scans[path]
        relative = relative_path(path, root)
        for module, offset in import_modules(scan):
            if module == "FoundationModels" and not _offset_in_ranges(
                offset, compile_ranges[path]
            ):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, offset),
                        "w3-compile-gate",
                        "FoundationModels import must be inside the positive branch "
                        "of #if canImport(FoundationModels)",
                    )
                )
    combined = "\n".join(scans[path].masked for path in sorted(relevant))
    if re.search(r"\bSystemLanguageModel\s*\.\s*default\b", combined) is None:
        violations.append(
            Violation("<repository>", 1, "w3-model", "W3 must use SystemLanguageModel.default")
        )
    if not any(model_availability_ranges[path] for path in relevant):
        violations.append(
            Violation(
                "<repository>",
                1,
                "w3-availability",
                "W3 must guard control flow with "
                "SystemLanguageModel.default.availability == .available",
            )
        )
    for path in sorted(relevant):
        scan = scans[path]
        relative = relative_path(path, root)
        for match in W3_FRAMEWORK_USE_PATTERN.finditer(scan.masked):
            if not _offset_in_ranges(match.start(), compile_ranges[path]):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, match.start()),
                        "w3-compile-gate",
                        f"Foundation Models use {match.group(0).strip()} must be "
                        "inside #if canImport(FoundationModels)",
                    )
                )
            if (
                re.match(r"(?:respond|streamResponse)\s*\(", match.group(0))
                and not _offset_in_ranges(
                    match.start(), model_availability_ranges[path]
                )
            ):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, match.start()),
                        "w3-availability",
                        "each Foundation Models response must be dominated by "
                        "a SystemLanguageModel.default availability guard",
                    )
                )
            if not _offset_in_ranges(match.start(), runtime_ranges[path]):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, match.start()),
                        "w3-runtime-gate",
                        f"Foundation Models use {match.group(0).strip()} must be "
                        "inside an iOS 26 @available declaration or #available branch",
                    )
                )
        for declaration in declarations[path]:
            if declaration.generable and (
                not _offset_in_ranges(declaration.start, compile_ranges[path])
                or not _offset_in_ranges(declaration.closing, compile_ranges[path])
            ):
                violations.append(
                    Violation(
                        relative,
                        line_number(scan.source, declaration.start),
                        "w3-compile-gate",
                        f"@Generable {declaration.name} must be wholly inside "
                        "#if canImport(FoundationModels)",
                    )
                )
        for offset, api in _w3_forbidden_api_uses(scan.masked):
            violations.append(
                Violation(
                    relative,
                    line_number(scan.source, offset),
                    "w3-forbidden-api",
                    f"Foundation Models boundary may not use {api}",
                )
            )
        for declaration in declarations[path]:
            violations.extend(_validate_w3_enum(relative, scan, declaration))
            for property_declaration in _properties(scan, declaration):
                violations.extend(
                    _validate_w3_property(
                        relative,
                        scan,
                        declaration,
                        property_declaration,
                        fixed_enums,
                    )
                )
        violations.extend(_w3_generated_calls(relative, scan, safe_types))
    return violations


def _exception_offsets(
    root: Path,
    exceptions: tuple[SafeException, ...],
) -> tuple[dict[tuple[str, str], set[int]], list[Violation]]:
    allowed: dict[tuple[str, str], set[int]] = {}
    violations: list[Violation] = []
    for exception in exceptions:
        path = root / exception.path
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            violations.append(
                Violation(exception.path, 1, "safe-exception", f"stale exception: {error}")
            )
            continue
        starts = [
            match.start()
            for match in re.finditer(re.escape(exception.snippet), source)
        ]
        if len(starts) != exception.expected_count:
            violations.append(
                Violation(
                    exception.path,
                    1,
                    "safe-exception",
                    f"expected {exception.expected_count} exact occurrence(s) "
                    f"for: {exception.reason}",
                )
            )
            continue
        token = "!" if exception.kind == "force-unwrap" else "print"
        token_offset = exception.snippet.rfind(token)
        allowed.setdefault((exception.path, exception.kind), set()).update(
            start + token_offset for start in starts
        )
    return allowed, violations


def validate_unsafe_swift(
    root: Path,
    exceptions: tuple[SafeException, ...] = SAFE_EXCEPTIONS,
) -> list[Violation]:
    allowed, violations = _exception_offsets(root, exceptions)
    for path in swift_sources(root):
        source = path.read_text(encoding="utf-8")
        scan = scan_swift(source)
        relative = relative_path(path, root)
        try_bangs = {
            match.end() - 1
            for match in re.finditer(r"\btry!", scan.masked)
        }
        for offset in sorted(try_bangs):
            if offset in allowed.get((relative, "try-force"), set()):
                continue
            violations.append(
                Violation(
                    relative,
                    line_number(source, offset),
                    "try-force",
                    "try! is not allowed",
                )
            )
        for match in re.finditer(r"(?<![A-Za-z0-9_])print\s*\(", scan.masked):
            offset = match.start() + match.group(0).find("print")
            if offset in allowed.get((relative, "print"), set()):
                continue
            violations.append(
                Violation(
                    relative,
                    line_number(source, offset),
                    "print",
                    "print(...) is not allowed",
                )
            )
        for offset, character in enumerate(scan.masked):
            if character != "!" or offset in try_bangs:
                continue
            if offset + 1 < len(scan.masked) and scan.masked[offset + 1] == "=":
                continue
            previous = scan.masked[offset - 1] if offset else ""
            if not (previous.isalnum() or previous in "_)]}"):
                continue
            if offset in allowed.get((relative, "force-unwrap"), set()):
                continue
            violations.append(
                Violation(
                    relative,
                    line_number(source, offset),
                    "force-unwrap",
                    "postfix ! is not allowed",
                )
            )
    return violations


def validate(root: Path = ROOT) -> list[Violation]:
    violations: list[Violation] = []
    for validator in (
        validate_core_imports,
        validate_view_posting_boundary,
        validate_colorsets,
        validate_static_localizations,
        validate_offline_boundary,
        validate_w3_foundation_models,
        validate_unsafe_swift,
    ):
        violations.extend(validator(root))
    return sorted(
        violations,
        key=lambda item: (item.path, item.line, item.rule, item.detail),
    )


def main() -> int:
    violations = validate()
    if violations:
        for violation in violations:
            print(f"error: {violation.render()}", file=sys.stderr)
        return 1
    print(
        "Validated architecture fitness: reviewed Core SHA-256 and OSLog seams, "
        "view posting boundary, declared colorsets, bilingual static UI keys, "
        "offline runtime, conditional Foundation Models boundary, and safe Swift"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
