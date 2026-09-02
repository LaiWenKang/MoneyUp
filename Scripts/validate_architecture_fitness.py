#!/usr/bin/env python3
"""Enforce reviewed architecture and source-safety boundaries.

The checks in this file intentionally describe narrow, reviewable seams. A new
dependency, color token, force unwrap, or Foundation Models output shape must
be added to the relevant declaration below instead of silently broadening a
regex exception.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from collections import Counter
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
        "#1F6047",
        "#A4E7CA",
    ),
    "App/MoneyUp/Assets.xcassets/BrandAction.colorset": (
        "#34785F",
        "#347F60",
        "#245F49",
        "#377B61",
    ),
    "App/MoneyUp/Assets.xcassets/BrandBackground.colorset": (
        "#F7F9F6",
        "#101512",
        "#FCFDFB",
        "#080B09",
    ),
    "App/MoneyUp/Assets.xcassets/BrandMist.colorset": (
        "#D4EAD8",
        "#3C6349",
        "#B8D9C4",
        "#557D64",
    ),
    "App/MoneyUp/Assets.xcassets/BrandSurface.colorset": (
        "#EEF4F0",
        "#18211D",
        "#E7EDE8",
        "#121A16",
    ),
    "App/MoneyUp/Assets.xcassets/BrandSurfaceElevated.colorset": (
        "#FAFBF9",
        "#202923",
        "#F3F6F2",
        "#17201B",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries1.colorset": (
        "#117733",
        "#59C69B",
        "#075F29",
        "#7EE0B2",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries2.colorset": (
        "#1F6680",
        "#68B7D0",
        "#00536D",
        "#8AD7EE",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries3.colorset": (
        "#8C6500",
        "#E0B44C",
        "#725000",
        "#FFD071",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries4.colorset": (
        "#7A3E9D",
        "#C68BE0",
        "#633080",
        "#E2A9F5",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries5.colorset": (
        "#A53F5B",
        "#E7899D",
        "#8B2947",
        "#FFA8B8",
    ),
    "App/MoneyUp/Assets.xcassets/ChartSeries6.colorset": (
        "#332288",
        "#9A8EE0",
        "#24126E",
        "#B9AEFF",
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
    "date",
    "memo",
    "merchant",
    "note",
    "payee",
    "price",
    "rate",
    "total",
    "transaction",
    "value",
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
    "byte",
    "bytes",
    "cloud",
    "data",
    "image",
    "package",
    "packages",
    "pcc",
    "provider",
    "receipt",
    "schema",
    "server",
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
    re.compile(r"\bLanguageModelSession\s*\(\s*[^)\s]"),
    re.compile(
        r"\b(?:DynamicGenerationSchema|GenerationSchema|GeneratedContent)\b"
    ),
)
W3_RESPONSE_CALL_NAME = (
    r"(?:\b(?:respond|streamResponse)|`(?:respond|streamResponse)`)"
)
W3_FRAMEWORK_USE_PATTERN = re.compile(
    r"@(?:Generable|Guide)\b|"
    r"\b(?:SystemLanguageModel|LanguageModelSession|GeneratedContent|"
    r"GenerationGuide|GenerationOptions|GenerationSchema|"
    r"DynamicGenerationSchema|Instructions|Prompt|Transcript|Tool|"
    r"ToolChoice)\b|"
    + W3_RESPONSE_CALL_NAME + r"\s*\("
)
W3_IOS_26_AVAILABILITY = re.compile(
    r"@available\s*\(\s*iOS\s+26(?:\.0)?\s*,[^)]*\)"
)
W3_REVIEWED_MODEL_PATH = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"
W3_REVIEWED_REQUEST_PATH = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
W3_REVIEWED_ENTRY_PATH = "App/MoneyUp/QuickLogEntryDraft.swift"
W3_REVIEWED_ENTRY_ASSISTANCE_PATH = (
    "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift"
)
W3_REVIEWED_AUTHORITY_PATH = "App/MoneyUp/QuickLogSheet.swift"
W3_REVIEWED_PARSER_PATH = "Sources/MoneyUpCore/NaturalLanguageEntryParser.swift"
W3_PRODUCT_MANIFEST_PATH = "project.yml"
W3_PRODUCTION_SENTINEL_PATH = "Sources/MoneyUpCore/UserProfile.swift"
W3_PRODUCTION_SENTINEL = re.compile(
    r"\bpublic\s+var\s+foundationModelAssistanceEnabled\s*:\s*Bool\b"
)
W3_PRODUCTION_TYPES = {
    "LocalOrdinalSelection": (W3_REVIEWED_MODEL_PATH, "struct"),
    "QuickLogOnDeviceOrdinalModel": (W3_REVIEWED_MODEL_PATH, "enum"),
    "ParsedNaturalLanguageEntry": (W3_REVIEWED_PARSER_PATH, "struct"),
    "QuickLogInputAuthority": (W3_REVIEWED_AUTHORITY_PATH, "enum"),
    "QuickLogAssistanceFieldState": (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "struct",
    ),
    "QuickLogAssistancePublicationBaseline": (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "struct",
    ),
    "QuickLogAssistancePublicationPolicy": (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "enum",
    ),
    "QuickLogAssistancePresentation": (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "struct",
    ),
    "QuickLogAssistanceChoice": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogAssistancePlan": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogAssistancePrompt": (W3_REVIEWED_REQUEST_PATH, "enum"),
    "QuickLogAssistanceResolution": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogAssistanceResolver": (W3_REVIEWED_REQUEST_PATH, "enum"),
    "QuickLogAssistanceCoordinator": (W3_REVIEWED_REQUEST_PATH, "class"),
    "QuickLogOrdinalPair": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogOrdinalRequest": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogOrdinalSelector": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "QuickLogPromptBoundary": (W3_REVIEWED_REQUEST_PATH, "enum"),
    "QuickLogPromptComponent": (W3_REVIEWED_REQUEST_PATH, "struct"),
    "NaturalLanguageEntryParser": (W3_REVIEWED_PARSER_PATH, "enum"),
}

# These headers and executable digests freeze the complete reviewed production
# boundary. The parser digest is intentionally sourced from cdd8743c: its local
# name/token projection helpers form one security dependency closure. Digests
# ignore comments and formatting but include every executable token and literal.
W3_TYPE_DECLARATION_INVENTORIES = {
    "LocalOrdinalSelection": "private struct LocalOrdinalSelection",
    "QuickLogOnDeviceOrdinalModel": "enum QuickLogOnDeviceOrdinalModel",
    "ParsedNaturalLanguageEntry": (
        "public struct ParsedNaturalLanguageEntry: Equatable, Sendable"
    ),
    "NaturalLanguageEntryParser": "public enum NaturalLanguageEntryParser",
    "QuickLogInputAuthority": "enum QuickLogInputAuthority",
    "QuickLogAssistanceFieldState": (
        "struct QuickLogAssistanceFieldState: Equatable"
    ),
    "QuickLogAssistancePublicationBaseline": (
        "struct QuickLogAssistancePublicationBaseline: Equatable"
    ),
    "QuickLogAssistancePublicationPolicy": (
        "enum QuickLogAssistancePublicationPolicy"
    ),
    "QuickLogAssistancePresentation": (
        "struct QuickLogAssistancePresentation: Equatable"
    ),
    "QuickLogPromptComponent": (
        "struct QuickLogPromptComponent: Equatable, Sendable"
    ),
    "QuickLogPromptBoundary": "enum QuickLogPromptBoundary",
    "QuickLogOrdinalRequest": (
        "struct QuickLogOrdinalRequest: Equatable, Sendable"
    ),
    "QuickLogOrdinalPair": "struct QuickLogOrdinalPair: Equatable, Sendable",
    "QuickLogAssistanceChoice": (
        "struct QuickLogAssistanceChoice: Equatable, Sendable"
    ),
    "QuickLogAssistancePlan": (
        "struct QuickLogAssistancePlan: Equatable, Sendable"
    ),
    "QuickLogAssistanceResolution": (
        "struct QuickLogAssistanceResolution: Equatable, Sendable"
    ),
    "QuickLogOrdinalSelector": "struct QuickLogOrdinalSelector: Sendable",
    "QuickLogAssistancePrompt": "enum QuickLogAssistancePrompt",
    "QuickLogAssistanceResolver": "enum QuickLogAssistanceResolver",
    "QuickLogAssistanceCoordinator": "final class QuickLogAssistanceCoordinator",
}
W3_TYPE_ATTRIBUTE_INVENTORIES = {
    "LocalOrdinalSelection": ("@available(iOS 26.0, *)", "@Generable"),
    "QuickLogOnDeviceOrdinalModel": ("@available(iOS 26.0, *)",),
    "QuickLogInputAuthority": ("@MainActor",),
    "QuickLogAssistanceCoordinator": ("@MainActor",),
}
W3_TYPE_EXECUTABLE_DIGESTS = {
    "LocalOrdinalSelection": (
        "dcdff228cf26ed1b8a443d5d41961ff082f007d3eb11fe5e12d8058c2209ee03"
    ),
    "QuickLogOnDeviceOrdinalModel": (
        "92fe2760d24d21c4af2fab73c73d7e51202003db1aa591882c14ec7aedc75d2d"
    ),
    "ParsedNaturalLanguageEntry": (
        "6cf9966b153ca11e1c66bb4fd877d7285f75b73acb7ec1d7c5dd540fc0c9c71a"
    ),
    "NaturalLanguageEntryParser": (
        "26bdbb8806cc592a5be0ff1663a452075fdad08fa59b4ec48d4c72b71cb9ae2b"
    ),
    "QuickLogInputAuthority": (
        "973c735265e2cc2bff6e170ce3d45fcc19655792ce9c0ee4397687fa4c6068b1"
    ),
    "QuickLogAssistanceFieldState": (
        "43826b6d4cd4e18804656b9777a14cd9b3862b07ee06f94cdbcbe61927c85cd9"
    ),
    "QuickLogAssistancePublicationBaseline": (
        "19e1de546ecd620eb57448ad728aebc7b3f103f6fea1e96862f793c6135a3509"
    ),
    "QuickLogAssistancePublicationPolicy": (
        "7d2fdbc47d125e4855976c4be099fa233787775b48a341fea06a7d2147ae63b3"
    ),
    "QuickLogAssistancePresentation": (
        "f4fff82bb445ce989337369d9357848909bed4c118afc6d55751c216282d3c02"
    ),
    "QuickLogPromptComponent": (
        "cf648db002a0e8e39ab63c8dd0f41018fb2a126a8a734414acde4ece5db00b8c"
    ),
    "QuickLogPromptBoundary": (
        "3d83b578faf8c7fecd780368deb80e9e70cf4cc6027a483e672f3f4f302e8969"
    ),
    "QuickLogOrdinalRequest": (
        "34b4194b7754edfc52c242556392593755cab032d1ade8db1697a2c21b7d46e2"
    ),
    "QuickLogOrdinalPair": (
        "0c14d06d02ca79982621d147f0fcf18d77d3b5eeba5107b2196636b181aca0cc"
    ),
    "QuickLogAssistanceChoice": (
        "8c4f9524847ced4c5512d0f0546700e4ceb4e5cff79551940bda9bbeb323383c"
    ),
    "QuickLogAssistancePlan": (
        "399a9c31a3a74643affb008f26ea0a5b22511968eca39433351a9d42dd00ab2c"
    ),
    "QuickLogAssistanceResolution": (
        "e5c8ab015fd46b3f731e1cf0c2fa3fe94a8d89dba1a69814b0d6156789d834d4"
    ),
    "QuickLogOrdinalSelector": (
        "4df70ad6fa52d379c392f3592bb27337ab9e74c5a3784337944357f62a3e95f3"
    ),
    "QuickLogAssistancePrompt": (
        "5247eaf788bf9ee48572107bd13b448862bcd9e77c4a76dca341bff806e64246"
    ),
    "QuickLogAssistanceResolver": (
        "4ce5f71dc043c0214c4f484ae560bce3d641acdb41dc6e6ac889f4e1c2d3ced3"
    ),
    "QuickLogAssistanceCoordinator": (
        "f5e7e2dd344244c6adf33e29fc8e8efc8a0d7da3ef1a11e60402d73adfca7e82"
    ),
}

W3_TOP_LEVEL_TYPE_INVENTORIES = {
    W3_REVIEWED_MODEL_PATH: (
        ("struct", "LocalOrdinalSelection"),
        ("enum", "QuickLogOnDeviceOrdinalModel"),
    ),
    W3_REVIEWED_REQUEST_PATH: (
        ("struct", "QuickLogPromptComponent"),
        ("enum", "QuickLogPromptBoundary"),
        ("struct", "QuickLogOrdinalRequest"),
        ("struct", "QuickLogOrdinalPair"),
        ("struct", "QuickLogAssistanceChoice"),
        ("struct", "QuickLogAssistancePlan"),
        ("struct", "QuickLogAssistanceResolution"),
        ("struct", "QuickLogOrdinalSelector"),
        ("enum", "QuickLogAssistancePrompt"),
        ("enum", "QuickLogAssistanceResolver"),
        ("class", "QuickLogAssistanceCoordinator"),
    ),
    W3_REVIEWED_PARSER_PATH: (
        ("struct", "ParsedNaturalLanguageEntry"),
        ("enum", "NaturalLanguageEntryParser"),
    ),
    W3_REVIEWED_ENTRY_ASSISTANCE_PATH: (
        ("struct", "QuickLogAssistanceFieldState"),
        ("struct", "QuickLogAssistancePublicationBaseline"),
        ("enum", "QuickLogAssistancePublicationPolicy"),
        ("struct", "QuickLogAssistancePresentation"),
        ("extension", "QuickLogEntryView"),
    ),
}

# Any new reference is a new construction, alias, consumer, or extension of a
# reviewed boundary type. Legitimate additions must be reviewed and counted.
W3_TYPE_REFERENCE_INVENTORIES = {
    "QuickLogInputAuthority": (
        ("App/MoneyUp/QuickLogEntryBody.swift", 1),
        (W3_REVIEWED_ENTRY_PATH, 1),
        ("App/MoneyUp/QuickLogEntryReceiptCandidates.swift", 1),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
    "NaturalLanguageEntryParser": (
        (W3_REVIEWED_ENTRY_PATH, 1),
        (W3_REVIEWED_PARSER_PATH, 1),
    ),
    "ParsedNaturalLanguageEntry": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 1),
        (W3_REVIEWED_REQUEST_PATH, 1),
        (W3_REVIEWED_PARSER_PATH, 3),
    ),
    "QuickLogPromptBoundary": ((W3_REVIEWED_REQUEST_PATH, 8),),
    "QuickLogPromptComponent": ((W3_REVIEWED_REQUEST_PATH, 18),),
    "QuickLogAssistanceChoice": ((W3_REVIEWED_REQUEST_PATH, 10),),
    "QuickLogAssistancePlan": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 3),
        (W3_REVIEWED_REQUEST_PATH, 6),
    ),
    "QuickLogOrdinalRequest": (
        (W3_REVIEWED_REQUEST_PATH, 8),
        (W3_REVIEWED_MODEL_PATH, 1),
    ),
    "QuickLogOrdinalPair": (
        (W3_REVIEWED_REQUEST_PATH, 5),
        (W3_REVIEWED_MODEL_PATH, 2),
    ),
    "QuickLogOrdinalSelector": ((W3_REVIEWED_REQUEST_PATH, 5),),
    "QuickLogOnDeviceOrdinalModel": (
        (W3_REVIEWED_REQUEST_PATH, 1),
        (W3_REVIEWED_MODEL_PATH, 1),
    ),
    "QuickLogAssistanceResolver": ((W3_REVIEWED_REQUEST_PATH, 2),),
    "QuickLogAssistanceResolution": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 7),
        (W3_REVIEWED_REQUEST_PATH, 4),
    ),
    "QuickLogAssistanceFieldState": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 27),
    ),
    "QuickLogAssistancePublicationBaseline": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 3),
    ),
    "QuickLogAssistancePublicationPolicy": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 2),
    ),
    "QuickLogAssistancePresentation": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 3),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
}

W3_STATE_REFERENCE_INVENTORIES = {
    "scanReceipt": (
        ("App/MoneyUp/AppModelLifecycle.swift", 2),
        ("App/MoneyUp/MoneyUpAppShortcuts.swift", 1),
        ("App/MoneyUp/QuickLogEntryBody.swift", 1),
        (W3_REVIEWED_ENTRY_PATH, 1),
        ("App/MoneyUp/QuickLogEntryReceipt.swift", 1),
        ("App/MoneyUp/QuickLogLaunchMode.swift", 4),
        ("App/Shared/MoneyUpQuickAction.swift", 7),
    ),
    "receiptScanTask": (
        ("App/MoneyUp/QuickLogEntryBody.swift", 4),
        ("App/MoneyUp/QuickLogEntryCommit.swift", 2),
        ("App/MoneyUp/QuickLogEntryReceipt.swift", 1),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
    "receiptScanGeneration": (
        ("App/MoneyUp/QuickLogEntryBody.swift", 2),
        ("App/MoneyUp/QuickLogEntryCommit.swift", 1),
        ("App/MoneyUp/QuickLogEntryReceipt.swift", 1),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
    "onDeviceAssistance": (
        ("App/MoneyUp/QuickLogEntryComponents.swift", 2),
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 11),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
    "onDeviceAssistanceTask": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 3),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
    "onDeviceAssistanceCoordinator": (
        (W3_REVIEWED_ENTRY_ASSISTANCE_PATH, 2),
        (W3_REVIEWED_AUTHORITY_PATH, 1),
    ),
}

W3_SOURCE_FUNCTION_DIGESTS: tuple[
    tuple[str, str, re.Pattern[str], str], ...
] = (
    (
        W3_PRODUCTION_SENTINEL_PATH,
        "UserProfile.init",
        re.compile(
            r"\bpublic\s+init\s*\(\s*baseCurrency\s*:\s*CurrencyCode\s*,"
            r"[^{};]*\)\s*\{",
            re.DOTALL,
        ),
        "7b993e418b998dd35f319f3eac95c250c5d11b702d9827d767045ae0738e6f07",
    ),
    (
        W3_PRODUCTION_SENTINEL_PATH,
        "UserProfile.init(from:)",
        re.compile(
            r"\bpublic\s+init\s*\(\s*from\s+decoder\s*:\s*Decoder\s*\)"
            r"\s*throws\s*\{"
        ),
        "39556b1f6a155d9fcffae5abb9a697e819444ffb1cf214d3d78c417e26c4ab8d",
    ),
    (
        W3_REVIEWED_ENTRY_PATH,
        "applyTypedPhrase",
        re.compile(r"\bfunc\s+applyTypedPhrase\s*\(\s*\)\s*\{"),
        "9e3838b664bf4bd5795a7982316929867defdd88e69dac56dd0eab8dc431fbc5",
    ),
    (
        "App/MoneyUp/QuickLogEntryDraft.swift",
        "reloadDraftForLogicalBookReplacement",
        re.compile(
            r"\bfunc\s+reloadDraftForLogicalBookReplacement\s*\(\s*\)\s*\{"
        ),
        "daa02b37a888d29954e12d17b64bd0b4ebf2cfb16345fb8d553755b94d983d0b",
    ),
    (
        "App/MoneyUp/QuickLogEntryCaptureSuggestions.swift",
        "clearPerTransactionReviewState",
        re.compile(r"\bfunc\s+clearPerTransactionReviewState\s*\(\s*\)\s*\{"),
        "93d66884bdf84c7b3c9ee5d570076d5a3ed27410ddf8d7ce0b56cc613db2bfde",
    ),
    (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "startOnDeviceAssistance",
        re.compile(
            r"\bfunc\s+startOnDeviceAssistance\s*\(\s*for\s+parsed\s*:"
            r"\s*ParsedNaturalLanguageEntry\s*\)\s*\{"
        ),
        "82faaeab814a53ea1afddd48e683b81f57825317fd99f92e613cf26e191bc598",
    ),
)

W3_PATH_TYPE_DIGESTS: tuple[tuple[str, str, str, str], ...] = (
    (
        "App/MoneyUp/QuickLogEntryBody.swift",
        "extension",
        "QuickLogEntryView",
        "58dc2110d6d842f32391746c4b7352ec55fe8e692a02d5a8ab58b37dd362c6ae",
    ),
    (
        "App/MoneyUp/QuickLogEntryReceipt.swift",
        "extension",
        "QuickLogEntryView",
        "dbe4d89116665a44914344752b06870f387f0b068b1cc2a6ad4fff4242c004ff",
    ),
    (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "extension",
        "QuickLogEntryView",
        "47ff6706a3bd31ac16a2e5213ac09660afc3ec15cbf0ad41fbb6f9eef520027e",
    ),
    (
        "App/MoneyUp/QuickLogEntryReceiptCandidates.swift",
        "extension",
        "QuickLogEntryView",
        "f02cd98a90fc8eb4c519643f3212bdf6f0d8aab93126802f413449f893de0c81",
    ),
)
W3_PATH_TYPE_ATTRIBUTES = {
    (
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
        "extension",
        "QuickLogEntryView",
    ): ("@MainActor",),
}
W3_PRODUCTION_LIMITS = {
    ("QuickLogAssistancePlan", "maximumChoiceCount"): "16",
    ("QuickLogPromptBoundary", "maximumContextScalarCount"): "128",
    ("QuickLogPromptBoundary", "maximumContextUTF8Count"): "256",
    ("QuickLogPromptBoundary", "maximumChoiceScalarCount"): "48",
    ("QuickLogPromptBoundary", "maximumChoiceUTF8Count"): "96",
    ("QuickLogPromptBoundary", "maximumPromptScalarCount"): "3_072",
    ("QuickLogPromptBoundary", "maximumPromptUTF8Count"): "4_096",
}
W3_FORBIDDEN_INPUT_TOKENS = {
    "amount",
    "arbitrary",
    "byte",
    "bytes",
    "currency",
    "data",
    "date",
    "id",
    "identifier",
    "image",
    "memo",
    "merchant",
    "money",
    "note",
    "ocr",
    "payee",
    "raw",
    "receipt",
    "transaction",
    "uuid",
}


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
        path="App/Shared/MoneyUpQuickAction.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/expense")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/Shared/MoneyUpQuickAction.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/income")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/Shared/MoneyUpQuickAction.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/transfer")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/Shared/MoneyUpQuickAction.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/refund")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/Shared/MoneyUpQuickAction.swift",
        kind="force-unwrap",
        snippet='URL(string: "moneyup://quick-log/smart-entry")!',
        expected_count=1,
        reason="the fixed MoneyUp deep link is a valid URL",
    ),
    SafeException(
        path="App/Shared/MoneyUpQuickAction.swift",
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
        path="App/MoneyUp/KeyCliffRecoveryTransaction.swift",
        kind="local-url-load",
        snippet="Data(contentsOf: manifestURL(for: databaseURL))",
        expected_count=1,
        reason=(
            "the private recovery manifest URL is derived only from the "
            "owned local SQLCipher database URL"
        ),
    ),
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


def _colorset_values(payload: object) -> tuple[str, str, str, str]:
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
        elif appearances == [{"appearance": "contrast", "value": "high"}]:
            slot = "light-high"
        elif appearances == [
            {"appearance": "luminosity", "value": "dark"},
            {"appearance": "contrast", "value": "high"},
        ]:
            slot = "dark-high"
        else:
            raise ValueError(
                "only universal light/dark normal/high-contrast slots are reviewed"
            )
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
    required_slots = {"light", "dark", "light-high", "dark-high"}
    if set(slots) != required_slots:
        raise ValueError("all light/dark normal/high-contrast slots are required")
    return (
        slots["light"],
        slots["dark"],
        slots["light-high"],
        slots["dark-high"],
    )


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
            and 0 <= int(guide.group(1)) <= int(guide.group(2)) <= 15
        )
        if not bounded_name or not bounded_guide:
            violations.append(
                Violation(
                    relative,
                    line,
                    "w3-output-shape",
                    "generated Int must be an ordinal/template identifier with "
                    "a literal closed @Guide range within 0...15",
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
    for match in re.finditer(W3_RESPONSE_CALL_NAME + r"\s*\(", scan.masked):
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
    return compact == "canImport(FoundationModels)"


def _w3_compile_ranges(masked: str) -> list[tuple[int, int]]:
    """Return lines where every enclosing compile branch is the exact gate."""
    ranges: list[tuple[int, int]] = []
    branches: list[bool] = []
    offset = 0
    for line in masked.splitlines(keepends=True):
        directive = re.match(r"^[ \t]*#(if|elseif|else|endif)\b(.*)$", line)
        if directive is None:
            if branches and all(branches):
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


def _w3_call_sites(
    scans: dict[Path, SwiftScan],
    pattern: re.Pattern[str],
) -> list[tuple[Path, SwiftScan, re.Match[str], str]]:
    sites: list[tuple[Path, SwiftScan, re.Match[str], str]] = []
    for path, scan in scans.items():
        for match in pattern.finditer(scan.masked):
            opening = scan.masked.find("(", match.start())
            closing = find_matching(scan.masked, opening, "(", ")")
            if closing is None:
                arguments = ""
            else:
                arguments = scan.masked[opening + 1:closing]
            sites.append((path, scan, match, arguments))
    return sites


def _w3_boundary_violation(
    root: Path,
    path: Path | None,
    scan: SwiftScan | None,
    offset: int,
    detail: str,
) -> Violation:
    return Violation(
        relative_path(path, root) if path is not None else "<repository>",
        line_number(scan.source, offset) if scan is not None else 1,
        "w3-input-boundary",
        detail,
    )


def _w3_production_is_enabled(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> bool:
    independent_paths = (
        W3_PRODUCT_MANIFEST_PATH,
        W3_PRODUCTION_SENTINEL_PATH,
        W3_REVIEWED_MODEL_PATH,
        W3_REVIEWED_REQUEST_PATH,
        W3_REVIEWED_ENTRY_PATH,
        W3_REVIEWED_ENTRY_ASSISTANCE_PATH,
    )
    return any((root / relative).is_file() for relative in independent_paths)


def _w3_direct_member_bodies(
    scan: SwiftScan,
    declaration: TypeDeclaration,
    pattern: re.Pattern[str],
) -> list[tuple[int, int, int]]:
    """Return direct member declaration/body ranges inside one named type."""
    result: list[tuple[int, int, int]] = []
    body_start = declaration.opening + 1
    for match in pattern.finditer(
        scan.masked,
        body_start,
        declaration.closing,
    ):
        prefix = scan.masked[body_start:match.start()]
        if prefix.count("{") != prefix.count("}"):
            continue
        opening = match.end() - 1
        closing = find_matching(scan.masked, opening)
        if closing is not None and closing <= declaration.closing:
            result.append((match.start(), opening + 1, closing))
    return result


def _w3_compact_inventory(masked: str) -> str:
    return re.sub(r"\s+", " ", masked).strip()


def _w3_expected_inventory(source: str) -> str:
    return _w3_compact_inventory(scan_swift(source).masked)


def _w3_literal_inventory(
    scan: SwiftScan,
    start: int,
    end: int,
) -> tuple[str, ...]:
    return tuple(
        scan.source[literal.start:literal.end]
        for literal in sorted(scan.strings, key=lambda value: value.start)
        if start <= literal.start and literal.end <= end
    )


def _w3_executable_digest(
    scan: SwiftScan,
    start: int,
    end: int,
) -> str:
    payload = _w3_compact_inventory(scan.masked[start:end]) + "\0"
    payload += json.dumps(
        _w3_literal_inventory(scan, start, end),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


W3_MEMBER_INVENTORIES: tuple[
    tuple[str, str, str, re.Pattern[str], str], ...
] = (
    (
        W3_REVIEWED_PARSER_PATH,
        "ParsedNaturalLanguageEntry",
        "init",
        re.compile(
            r"\bpublic\s+init\s*\(\s*draft\s*:\s*TransactionDraft\s*,"
            r"\s*context\s*:\s*String\?\s*\)\s*\{"
        ),
        r"""
        self.draft = draft
        self.context = context
        """,
    ),
    (
        W3_REVIEWED_PARSER_PATH,
        "NaturalLanguageEntryParser",
        "assistanceContext",
        re.compile(
            r"\bprivate\s+static\s+func\s+assistanceContext\s*\("
            r"\s*from\s+remainder\s*:\s*String\s*,"
            r"\s*currencyCodes\s*:\s*Set\s*<\s*String\s*>\s*,"
            r"\s*localNames\s*:\s*\[\s*String\s*\]\s*\)"
            r"\s*->\s*String\?\s*\{"
        ),
        r"""
        let comparableCurrencyCodes = Set(
            currencyCodes.map(assistanceComparisonKey)
        )
        let separators = CharacterSet.decimalDigits
            .union(.symbols)
            .union(.punctuationCharacters)
        var sanitized = ""
        for scalar in remainder.precomposedStringWithCompatibilityMapping.unicodeScalars {
            let properties = scalar.properties
            let category = properties.generalCategory
            if properties.isDefaultIgnorableCodePoint || category == .format {
                continue
            }
            if separators.contains(scalar)
                || category == .control {
                sanitized.append(" ")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        let trimSet = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
            .union(fillerCharacters)
        let words = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { word in
                guard !word.isEmpty else { return false }
                let lowered = word.lowercased()
                if fillerWords.contains(lowered) { return false }
                let comparisonKey = assistanceComparisonKey(word)
                if comparableCurrencyCodes.contains(comparisonKey) {
                    return false
                }
                let asciiLetters = word.unicodeScalars.allSatisfy {
                    (65...90).contains($0.value) || (97...122).contains($0.value)
                }
                return !(asciiLetters && word.count == 3
                    && word == word.uppercased())
            }
        let fullContext = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullContext.isEmpty,
              fullContext.contains(where: { $0.isLetter }),
              !containsLocalName(fullContext, localNames: localNames),
              let boundedContext = boundedAssistanceContext(words),
              boundedContext.contains(where: { $0.isLetter }),
              !containsLocalName(boundedContext, localNames: localNames)
        else { return nil }
        return boundedContext
        """,
    ),
    (
        W3_REVIEWED_PARSER_PATH,
        "NaturalLanguageEntryParser",
        "boundedAssistanceContext",
        re.compile(
            r"\bprivate\s+static\s+func\s+boundedAssistanceContext\s*\("
            r"\s*_\s+words\s*:\s*\[\s*String\s*\]\s*\)"
            r"\s*->\s*String\?\s*\{"
        ),
        r"""
        var context = ""
        var scalarCount = 0
        var utf8Count = 0
        for word in words {
            let separatorCount = context.isEmpty ? 0 : 1
            let nextScalarCount = scalarCount + separatorCount
                + word.unicodeScalars.count
            let nextUTF8Count = utf8Count + separatorCount + word.utf8.count
            guard nextScalarCount <= 128, nextUTF8Count <= 256 else { break }
            if separatorCount == 1 {
                context.append(" ")
            }
            context.append(word)
            scalarCount = nextScalarCount
            utf8Count = nextUTF8Count
        }
        return context.isEmpty ? nil : context
        """,
    ),
    (
        W3_REVIEWED_PARSER_PATH,
        "NaturalLanguageEntryParser",
        "containsLocalName",
        re.compile(
            r"\bprivate\s+static\s+func\s+containsLocalName\s*\("
            r"\s*_\s+context\s*:\s*String\s*,"
            r"\s*localNames\s*:\s*\[\s*String\s*\]\s*\)"
            r"\s*->\s*Bool\s*\{"
        ),
        r"""
        let projectedContext = searchProjection(of: context).text
        return localNames.contains { name in
            let projectedName = searchProjection(
                of: TextScanner.normalized(name)
            ).text
            return firstProjectedTokenRange(
                of: projectedName,
                in: projectedContext
            ) != nil
        }
        """,
    ),
    (
        W3_REVIEWED_PARSER_PATH,
        "NaturalLanguageEntryParser",
        "assistanceComparisonKey",
        re.compile(
            r"\bprivate\s+static\s+func\s+assistanceComparisonKey\s*\("
            r"\s*_\s+value\s*:\s*String\s*\)\s*->\s*String\s*\{"
        ),
        r"""
        let locale = Locale(identifier: "en_US_POSIX")
        return value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogPromptComponent",
        "init",
        re.compile(
            r"\bprivate\s+init\s*\(\s*text\s*:\s*String\s*\)\s*\{"
        ),
        "self.text = text",
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogPromptComponent",
        "context",
        re.compile(
            r"\bstatic\s+func\s+context\s*\(\s*_\s+value\s*:\s*String\s*\)"
            r"\s*->\s*QuickLogPromptComponent\?\s*\{"
        ),
        r"""
        QuickLogPromptBoundary.normalized(
            value,
            maximumScalarCount: QuickLogPromptBoundary.maximumContextScalarCount,
            maximumUTF8Count: QuickLogPromptBoundary.maximumContextUTF8Count
        ).map { QuickLogPromptComponent(text: $0) }
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogPromptComponent",
        "choice",
        re.compile(
            r"\bstatic\s+func\s+choice\s*\(\s*_\s+value\s*:\s*String\s*\)"
            r"\s*->\s*QuickLogPromptComponent\?\s*\{"
        ),
        r"""
        QuickLogPromptBoundary.normalized(
            value,
            maximumScalarCount: QuickLogPromptBoundary.maximumChoiceScalarCount,
            maximumUTF8Count: QuickLogPromptBoundary.maximumChoiceUTF8Count
        ).map { QuickLogPromptComponent(text: $0) }
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogPromptBoundary",
        "normalized",
        re.compile(
            r"\bstatic\s+func\s+normalized\s*\(\s*_\s+value\s*:\s*String\s*,"
            r"\s*maximumScalarCount\s*:\s*Int\s*,\s*maximumUTF8Count\s*:\s*Int"
            r"\s*\)\s*->\s*String\?\s*\{"
        ),
        r"""
        let canonical = value.precomposedStringWithCompatibilityMapping
        var collapsed = ""
        var pendingSpace = false
        for scalar in canonical.unicodeScalars {
            let properties = scalar.properties
            if properties.isDefaultIgnorableCodePoint
                || properties.generalCategory == .format {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            guard properties.generalCategory != .control else {
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.unicodeScalars.append(scalar)
        }

        let normalized = collapsed.precomposedStringWithCanonicalMapping
        var result = ""
        var scalarCount = 0
        var utf8Count = 0
        for character in normalized {
            let fragment = String(character)
            let fragmentScalarCount = fragment.unicodeScalars.count
            let fragmentUTF8Count = fragment.utf8.count
            guard scalarCount + fragmentScalarCount <= maximumScalarCount,
                  utf8Count + fragmentUTF8Count <= maximumUTF8Count else {
                break
            }
            result.append(character)
            scalarCount += fragmentScalarCount
            utf8Count += fragmentUTF8Count
        }
        return result.isEmpty ? nil : result
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogPromptBoundary",
        "contains",
        re.compile(
            r"\bstatic\s+func\s+contains\s*\(\s*_\s+prompt\s*:\s*String\s*\)"
            r"\s*->\s*Bool\s*\{"
        ),
        r"""
        prompt.unicodeScalars.count <= maximumPromptScalarCount
            && prompt.utf8.count <= maximumPromptUTF8Count
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogOrdinalRequest",
        "init",
        re.compile(
            r"\bprivate\s+init\s*\(\s*context\s*:\s*QuickLogPromptComponent\s*,"
            r"\s*firstChoices\s*:\s*\[\s*QuickLogPromptComponent\s*\]\s*,"
            r"\s*secondChoices\s*:\s*\[\s*QuickLogPromptComponent\s*\]"
            r"\s*\)\s*\{"
        ),
        r"""
        self.context = context
        self.firstChoices = firstChoices
        self.secondChoices = secondChoices
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogOrdinalRequest",
        "make",
        re.compile(
            r"\bstatic\s+func\s+make\s*\(\s*plan\s*:\s*QuickLogAssistancePlan"
            r"\s*\)\s*->\s*QuickLogOrdinalRequest\?\s*\{"
        ),
        r"""
        guard let context = QuickLogPromptComponent.context(plan.context) else {
            return nil
        }
        let requestedAccounts = plan.accountChoices.count > 1
            ? plan.accountChoices : []
        let requestedCategories = plan.categoryChoices.count > 1
            ? plan.categoryChoices : []
        let firstChoices = requestedAccounts.compactMap {
            QuickLogPromptComponent.choice($0.label)
        }
        let secondChoices = requestedCategories.compactMap {
            QuickLogPromptComponent.choice($0.label)
        }
        guard firstChoices.count == requestedAccounts.count,
              secondChoices.count == requestedCategories.count,
              Set(firstChoices.map(\.text)).count == firstChoices.count,
              Set(secondChoices.map(\.text)).count == secondChoices.count else {
            return nil
        }
        let request = QuickLogOrdinalRequest(
            context: context,
            firstChoices: firstChoices,
            secondChoices: secondChoices
        )
        return request
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePlan",
        "init",
        re.compile(
            r"\binit\?\s*\(\s*context\s*:\s*String\s*,"
            r"\s*accountChoices\s*:\s*\[\s*QuickLogAssistanceChoice\s*\]\s*,"
            r"\s*categoryChoices\s*:\s*\[\s*QuickLogAssistanceChoice\s*\]"
            r"\s*\)\s*\{"
        ),
        r"""
        guard accountChoices.count <= Self.maximumChoiceCount,
              categoryChoices.count <= Self.maximumChoiceCount,
              Set(accountChoices.map(\.id)).count == accountChoices.count,
              Set(categoryChoices.map(\.id)).count == categoryChoices.count,
              let normalizedContext = QuickLogPromptComponent.context(context)?.text
        else { return nil }
        let normalizedAccounts = Self.normalizedChoices(accountChoices) ?? []
        let normalizedCategories = Self.normalizedChoices(categoryChoices) ?? []
        guard normalizedAccounts.count >= 2 || normalizedCategories.count >= 2
        else { return nil }
        self.context = normalizedContext
        self.accountChoices = normalizedAccounts
        self.categoryChoices = normalizedCategories
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePlan",
        "make",
        re.compile(
            r"\bstatic\s+func\s+make\s*\(\s*parsed\s*:\s*ParsedNaturalLanguageEntry\s*,"
            r"\s*accounts\s*:\s*\[\s*LedgerAccount\s*\]\s*,"
            r"\s*categories\s*:\s*\[\s*LedgerAccount\s*\]\s*,"
            r"\s*accountFieldWasEdited\s*:\s*Bool\s*,"
            r"\s*categoryFieldWasEdited\s*:\s*Bool\s*\)"
            r"\s*->\s*QuickLogAssistancePlan\?\s*\{"
        ),
        r"""
        guard let context = parsed.context else { return nil }
        let accountChoices = parsed.draft.accountID == nil
            && !accountFieldWasEdited
            ? boundedChoices(accounts) : []
        let categoryChoices = parsed.draft.categoryID == nil
            && !categoryFieldWasEdited
            ? boundedChoices(categories) : []
        return QuickLogAssistancePlan(
            context: context,
            accountChoices: accountChoices,
            categoryChoices: categoryChoices
        )
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePlan",
        "boundedChoices",
        re.compile(
            r"\bprivate\s+static\s+func\s+boundedChoices\s*\("
            r"\s*_\s+accounts\s*:\s*\[\s*LedgerAccount\s*\]\s*\)"
            r"\s*->\s*\[\s*QuickLogAssistanceChoice\s*\]\s*\{"
        ),
        r"""
        let bounded = accounts
            .filter { !$0.isArchived && $0.systemRole == nil }
            .compactMap { account in
                QuickLogPromptComponent.choice(account.name).map {
                    QuickLogAssistanceChoice(id: account.id, label: $0.text)
                }
            }
            .sorted { first, second in
                let firstKey = stableKey(first.label)
                let secondKey = stableKey(second.label)
                if firstKey == secondKey {
                    return first.id.uuidString < second.id.uuidString
                }
                return firstKey < secondKey
            }
            .prefix(maximumChoiceCount)
            .map { $0 }
        return normalizedChoices(bounded) ?? []
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePlan",
        "normalizedChoices",
        re.compile(
            r"\bprivate\s+static\s+func\s+normalizedChoices\s*\("
            r"\s*_\s+choices\s*:\s*\[\s*QuickLogAssistanceChoice\s*\]\s*\)"
            r"\s*->\s*\[\s*QuickLogAssistanceChoice\s*\]\?\s*\{"
        ),
        r"""
        let normalized = choices.compactMap { choice in
            QuickLogPromptComponent.choice(choice.label).map {
                QuickLogAssistanceChoice(id: choice.id, label: $0.text)
            }
        }
        guard normalized.count == choices.count,
              Set(normalized.map(\.label)).count == normalized.count else {
            return nil
        }
        return normalized
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePlan",
        "stableKey",
        re.compile(
            r"\bprivate\s+static\s+func\s+stableKey\s*\(\s*_\s+value\s*:\s*String"
            r"\s*\)\s*->\s*String\s*\{"
        ),
        r"""
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogOrdinalSelector",
        "init",
        re.compile(
            r"(?<![A-Za-z0-9_.])init\s*\(\s*_\s+implementation\s*:"
            r"\s*@escaping\s+@Sendable\s*\(\s*QuickLogOrdinalRequest\s*\)"
            r"\s*async\s+throws\s*->\s*QuickLogOrdinalPair\?\s*\)\s*\{"
        ),
        "self.implementation = implementation",
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogOrdinalSelector",
        "select",
        re.compile(
            r"\bfunc\s+select\s*\(\s*_\s+request\s*:"
            r"\s*QuickLogOrdinalRequest\s*\)\s*async\s+throws\s*->"
            r"\s*QuickLogOrdinalPair\?\s*\{"
        ),
        "try await implementation(request)",
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogOrdinalSelector",
        "live",
        re.compile(
            r"\bstatic\s+let\s+live\s*=\s*QuickLogOrdinalSelector"
            r"\s*\{"
        ),
        r"""
        request in
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await QuickLogOnDeviceOrdinalModel.select(
                request: request
            )
        }
#endif
        return nil
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistanceResolver",
        "resolve",
        re.compile(
            r"\bstatic\s+func\s+resolve\s*\(\s*plan\s*:"
            r"\s*QuickLogAssistancePlan\s*,\s*selector\s*:"
            r"\s*QuickLogOrdinalSelector\s*\)\s*async\s*->"
            r"\s*QuickLogAssistanceResolution\?\s*\{"
        ),
        r"""
        let requestsAccount = plan.accountChoices.count > 1
        let requestsCategory = plan.categoryChoices.count > 1
        guard requestsAccount || requestsCategory else { return nil }
        guard let request = QuickLogOrdinalRequest.make(plan: plan) else {
            return nil
        }
        let selection: QuickLogOrdinalPair
        do {
            guard let result = try await selector.select(request),
                  !Task.isCancelled else { return nil }
            selection = result
        } catch {
            return nil
        }
        guard (!requestsAccount
                || plan.accountChoices.indices.contains(selection.firstOrdinal)),
              (!requestsCategory
                || plan.categoryChoices.indices.contains(selection.secondOrdinal))
        else { return nil }
        let resolution = QuickLogAssistanceResolution(
            suggestedAccountID: requestsAccount
                ? plan.accountChoices[selection.firstOrdinal].id : nil,
            suggestedCategoryID: requestsCategory
                ? plan.categoryChoices[selection.secondOrdinal].id : nil
        )
        return resolution.isEmpty ? nil : resolution
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistanceCoordinator",
        "init",
        re.compile(
            r"(?<![A-Za-z0-9_.])init\s*\(\s*selector\s*:"
            r"\s*QuickLogOrdinalSelector\s*=\s*\.\s*live\s*\)\s*\{"
        ),
        "self.selector = selector",
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistanceCoordinator",
        "cancel",
        re.compile(r"\bfunc\s+cancel\s*\(\s*\)\s*\{"),
        "generation &+= 1",
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistanceCoordinator",
        "resolve",
        re.compile(
            r"\bfunc\s+resolve\s*\(\s*enabled\s*:\s*Bool\s*,"
            r"\s*planner\s*:\s*\(\s*\)\s*->"
            r"\s*QuickLogAssistancePlan\?\s*\)\s*async\s*->"
            r"\s*QuickLogAssistanceResolution\?\s*\{"
        ),
        r"""
        guard !Task.isCancelled else { return nil }
        generation &+= 1
        let startedGeneration = generation
        guard enabled else { return nil }
        guard let plan = planner() else { return nil }
        let result = await QuickLogAssistanceResolver.resolve(
            plan: plan,
            selector: selector
        )
        guard !Task.isCancelled,
              startedGeneration == generation else { return nil }
        return result
        """,
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePrompt",
        "text",
        re.compile(
            r"\bstatic\s+func\s+text\s*\(\s*for\s+request\s*:\s*QuickLogOrdinalRequest"
            r"\s*\)\s*->\s*String\?\s*\{"
        ),
        r'''
        let firstChoices = numbered(request.firstChoices)
        let secondChoices = numbered(request.secondChoices)
        let prompt = """
        Choose ordinals only from the two closed local lists.
        First ordinal: where the entry belongs.
        Second ordinal: why the entry happened.
        Use zero when a list says Not requested; that output will be ignored.
        Nonfinancial context: \(request.context.text)
        First closed list:
        \(firstChoices)
        Second closed list:
        \(secondChoices)
        """
        return QuickLogPromptBoundary.contains(prompt) ? prompt : nil
        ''',
    ),
    (
        W3_REVIEWED_REQUEST_PATH,
        "QuickLogAssistancePrompt",
        "numbered",
        re.compile(
            r"\bprivate\s+static\s+func\s+numbered\s*\("
            r"\s*_\s+choices\s*:\s*\[\s*QuickLogPromptComponent\s*\]\s*\)"
            r"\s*->\s*String\s*\{"
        ),
        r'''
        guard !choices.isEmpty else { return "Not requested" }
        return choices.enumerated().map { index, choice in
            "\(index): \(choice.text)"
        }.joined(separator: "\n")
        ''',
    ),
    (
        W3_REVIEWED_MODEL_PATH,
        "QuickLogOnDeviceOrdinalModel",
        "select",
        re.compile(
            r"\bstatic\s+func\s+select\s*\(\s*request\s*:\s*QuickLogOrdinalRequest"
            r"\s*\)\s*async\s+throws\s*->\s*QuickLogOrdinalPair\?\s*\{"
        ),
        r"""
        guard SystemLanguageModel.default.availability == .available else {
            return nil
        }
        guard let reviewedPrompt = QuickLogAssistancePrompt.text(
            for: request
        ) else { return nil }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: reviewedPrompt,
            generating: LocalOrdinalSelection.self
        )
        return QuickLogOrdinalPair(
            firstOrdinal: response.content.firstChoiceOrdinal,
            secondOrdinal: response.content.secondChoiceOrdinal
        )
        """,
    ),
)


W3_DIRECT_PROPERTY_INVENTORIES: dict[str, tuple[str, ...]] = {
    "LocalOrdinalSelection": (
        "var firstChoiceOrdinal: Int",
        "var secondChoiceOrdinal: Int",
    ),
    "QuickLogOnDeviceOrdinalModel": (),
    "ParsedNaturalLanguageEntry": (
        "public let draft: TransactionDraft",
        "public let context: String?",
    ),
    "QuickLogAssistanceChoice": (
        "let id: UUID",
        "let label: String",
    ),
    "QuickLogAssistancePlan": (
        "static let maximumChoiceCount = 16",
        "let context: String",
        "let accountChoices: [QuickLogAssistanceChoice]",
        "let categoryChoices: [QuickLogAssistanceChoice]",
        "var isEmpty: Bool {",
    ),
    "QuickLogAssistancePrompt": (),
    "QuickLogAssistanceResolution": (
        "let suggestedAccountID: UUID?",
        "let suggestedCategoryID: UUID?",
        "var isEmpty: Bool {",
    ),
    "QuickLogAssistanceResolver": (),
    "QuickLogAssistanceCoordinator": (
        "private let selector: QuickLogOrdinalSelector",
        "private var generation = 0",
    ),
    "QuickLogOrdinalPair": (
        "let firstOrdinal: Int",
        "let secondOrdinal: Int",
    ),
    "QuickLogOrdinalRequest": (
        "let context: QuickLogPromptComponent",
        "let firstChoices: [QuickLogPromptComponent]",
        "let secondChoices: [QuickLogPromptComponent]",
    ),
    "QuickLogOrdinalSelector": (
        "private let implementation: @Sendable (",
        "static let live = QuickLogOrdinalSelector { request in",
    ),
    "QuickLogPromptBoundary": (
        "static let maximumContextScalarCount = 128",
        "static let maximumContextUTF8Count = 256",
        "static let maximumChoiceScalarCount = 48",
        "static let maximumChoiceUTF8Count = 96",
        "static let maximumPromptScalarCount = 3_072",
        "static let maximumPromptUTF8Count = 4_096",
    ),
    "QuickLogPromptComponent": ("let text: String",),
}
W3_DIRECT_CALLABLE_INVENTORIES: dict[str, tuple[str, ...]] = {
    "LocalOrdinalSelection": (),
    "QuickLogOnDeviceOrdinalModel": ("select",),
    "ParsedNaturalLanguageEntry": ("init",),
    "QuickLogAssistanceChoice": (),
    "QuickLogAssistancePlan": (
        "init",
        "make",
        "boundedChoices",
        "normalizedChoices",
        "stableKey",
    ),
    "QuickLogAssistancePrompt": ("text", "numbered"),
    "QuickLogAssistanceResolution": (),
    "QuickLogAssistanceResolver": ("resolve",),
    "QuickLogAssistanceCoordinator": ("init", "cancel", "resolve"),
    "QuickLogOrdinalPair": (),
    "QuickLogOrdinalRequest": ("init", "make"),
    "QuickLogOrdinalSelector": ("init", "select"),
    "QuickLogPromptBoundary": ("normalized", "contains"),
    "QuickLogPromptComponent": ("init", "context", "choice"),
}


def _w3_named_production_types(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> tuple[dict[str, tuple[Path, SwiftScan, TypeDeclaration]], list[Violation]]:
    found: dict[str, tuple[Path, SwiftScan, TypeDeclaration]] = {}
    violations: list[Violation] = []
    for name, (expected_relative, expected_kind) in W3_PRODUCTION_TYPES.items():
        occurrences = [
            (path, scan, declaration)
            for path, scan in scans.items()
            for declaration in type_declarations(scan)
            if declaration.name == name
        ]
        expected_path = root / expected_relative
        if len(occurrences) != 1:
            violations.append(
                _w3_boundary_violation(
                    root,
                    None,
                    None,
                    0,
                    f"expected one canonical {name} declaration, found {len(occurrences)}",
                )
            )
            continue
        path, scan, declaration = occurrences[0]
        if path != expected_path or declaration.kind != expected_kind:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    f"{name} must remain the canonical {expected_kind} in "
                    f"{expected_relative}",
                )
            )
            continue
        found[name] = (path, scan, declaration)
    return found, violations


def _w3_leading_type_attributes(
    scan: SwiftScan,
    declaration: TypeDeclaration,
) -> tuple[str, ...]:
    attributes: list[str] = []
    cursor = scan.masked.rfind("\n", 0, declaration.start) + 1
    while cursor > 0:
        line_end = cursor - 1
        line_start = scan.masked.rfind("\n", 0, line_end) + 1
        line = _w3_compact_inventory(scan.masked[line_start:line_end])
        cursor = line_start
        if not line:
            continue
        if line.startswith("@"):
            attributes.append(line)
            continue
        break
    return tuple(reversed(attributes))


def _w3_production_type_inventories(
    root: Path,
    types: dict[str, tuple[Path, SwiftScan, TypeDeclaration]],
) -> list[Violation]:
    violations: list[Violation] = []
    for type_name, expected_declaration in W3_TYPE_DECLARATION_INVENTORIES.items():
        value = types.get(type_name)
        if value is None:
            continue
        path, scan, declaration = value
        line_start = scan.masked.rfind("\n", 0, declaration.start) + 1
        actual_declaration = _w3_compact_inventory(
            scan.masked[line_start:declaration.opening]
        )
        actual_attributes = _w3_leading_type_attributes(scan, declaration)
        actual_digest = _w3_executable_digest(
            scan,
            declaration.opening + 1,
            declaration.closing,
        )
        if (
            actual_declaration != expected_declaration
            or actual_attributes
            != W3_TYPE_ATTRIBUTE_INVENTORIES.get(type_name, ())
            or actual_digest != W3_TYPE_EXECUTABLE_DIGESTS[type_name]
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    f"reviewed {type_name} declaration or executable inventory "
                    "changed",
                )
            )
    return violations


def _w3_path_type_inventories(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    for relative, kind, type_name, expected_digest in W3_PATH_TYPE_DIGESTS:
        path = root / relative
        scan = scans.get(path)
        matches = (
            [
                declaration
                for declaration in type_declarations(scan)
                if declaration.kind == kind and declaration.name == type_name
            ]
            if scan is not None else []
        )
        if (
            scan is None
            or len(matches) != 1
            or _w3_leading_type_attributes(scan, matches[0])
            != W3_PATH_TYPE_ATTRIBUTES.get((relative, kind, type_name), ())
            or _w3_executable_digest(
                scan,
                matches[0].opening + 1,
                matches[0].closing,
            ) != expected_digest
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path if scan is not None else None,
                    scan,
                    matches[0].start if matches else 0,
                    f"reviewed {relative} {type_name} executable inventory changed",
                )
            )
    return violations


def _w3_profile_opt_in_inventory(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    path = root / W3_PRODUCTION_SENTINEL_PATH
    scan = scans.get(path)
    declarations = (
        [
            declaration
            for declaration in type_declarations(scan)
            if declaration.kind == "struct" and declaration.name == "UserProfile"
        ]
        if scan is not None else []
    )
    stored_gate = []
    if scan is not None and len(declarations) == 1:
        stored_gate = [
            property_value
            for property_value in _properties(scan, declarations[0])
            if property_value.name == "foundationModelAssistanceEnabled"
            and _w3_compact_inventory(property_value.type_name or "") == "Bool"
        ]
    default_count = (
        len(
            re.findall(
                r"\bfoundationModelAssistanceEnabled\s*:\s*Bool"
                r"\s*=\s*false\s*,",
                scan.masked,
            )
        )
        if scan is not None else 0
    )
    if len(declarations) == 1 and len(stored_gate) == 1 and default_count == 1:
        return []
    return [
        _w3_boundary_violation(
            root,
            path if scan is not None else None,
            scan,
            declarations[0].start if declarations else 0,
            "UserProfile Foundation Models assistance must remain a stored, "
            "explicit opt-in defaulting false",
        )
    ]


def _w3_quick_log_state_declaration_inventory(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    path = root / W3_REVIEWED_AUTHORITY_PATH
    scan = scans.get(path)
    declarations = (
        [
            declaration
            for declaration in type_declarations(scan)
            if declaration.kind == "struct"
            and declaration.name == "QuickLogEntryView"
        ]
        if scan is not None else []
    )
    pattern = re.compile(
        r"@State\s+var\s+onDeviceAssistanceCoordinator\s*=\s*"
        r"QuickLogAssistanceCoordinator\s*\(\s*\)\s*"
        r"@State\s+var\s+onDeviceAssistanceTask\s*:"
        r"\s*Task\s*<\s*Void\s*,\s*Never\s*>\s*\?\s*"
        r"@State\s+var\s+onDeviceAssistance\s*:"
        r"\s*QuickLogAssistancePresentation\s*\?\s*"
        r"@State\s+var\s+pendingDuplicateReview\s*:"
        r"\s*PendingDuplicateReview\s*\?"
    )
    matches = (
        _w3_direct_matches(scan, declarations[0], pattern)
        if scan is not None and len(declarations) == 1 else []
    )
    if len(matches) == 1:
        return []
    return [
        _w3_boundary_violation(
            root,
            path if scan is not None else None,
            scan,
            declarations[0].start if declarations else 0,
            "Quick Log assistance state must retain the reviewed empty/live "
            "initializer sequence",
        )
    ]


def _w3_production_top_level_inventories(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    declaration_token = re.compile(
        r"\b(?:struct|class|enum|actor|protocol|extension|typealias|func|"
        r"let|var|subscript|operator|precedencegroup)\b"
    )
    for relative, expected in W3_TOP_LEVEL_TYPE_INVENTORIES.items():
        path = root / relative
        scan = scans.get(path)
        if scan is None:
            continue
        declarations = tuple(
            (declaration.kind, declaration.name)
            for declaration in type_declarations(scan)
            if scan.masked[:declaration.start].count("{")
            == scan.masked[:declaration.start].count("}")
        )
        tokens = tuple(
            match
            for match in declaration_token.finditer(scan.masked)
            if scan.masked[:match.start()].count("{")
            == scan.masked[:match.start()].count("}")
        )
        if declarations != expected or len(tokens) != len(expected):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    0,
                    f"reviewed top-level declaration inventory changed in {relative}",
                )
            )
    return violations


def _w3_production_type_references(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    inventories = (
        ("type", W3_TYPE_REFERENCE_INVENTORIES),
        ("state", W3_STATE_REFERENCE_INVENTORIES),
    )
    for inventory_kind, inventory in inventories:
        for identifier, expected_values in inventory.items():
            pattern = re.compile(rf"\b{re.escape(identifier)}\b")
            actual = Counter(
                {
                    relative_path(path, root): count
                    for path, scan in scans.items()
                    if (count := len(pattern.findall(scan.masked)))
                }
            )
            expected = Counter(dict(expected_values))
            if actual == expected:
                continue
            violations.append(
                _w3_boundary_violation(
                    root,
                    None,
                    None,
                    0,
                    f"reviewed {identifier} production {inventory_kind} "
                    "reference inventory changed",
                )
            )
    return violations


def _w3_source_function_inventories(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    for relative, function_name, pattern, expected_digest in (
        W3_SOURCE_FUNCTION_DIGESTS
    ):
        path = root / relative
        scan = scans.get(path)
        matches = list(pattern.finditer(scan.masked)) if scan is not None else []
        ranges: list[tuple[int, int]] = []
        if scan is not None:
            for match in matches:
                opening = match.end() - 1
                closing = find_matching(scan.masked, opening)
                if closing is not None:
                    ranges.append((opening + 1, closing))
        if (
            scan is None
            or len(matches) != 1
            or len(ranges) != 1
            or _w3_executable_digest(scan, *ranges[0]) != expected_digest
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path if scan is not None else None,
                    scan,
                    matches[0].start() if matches else 0,
                    f"reviewed {function_name} executable inventory changed",
                )
            )
    return violations


def _w3_production_member_inventories(
    root: Path,
    types: dict[str, tuple[Path, SwiftScan, TypeDeclaration]],
) -> list[Violation]:
    violations: list[Violation] = []
    for relative, type_name, member_name, pattern, expected_source in (
        W3_MEMBER_INVENTORIES
    ):
        value = types.get(type_name)
        if value is None:
            continue
        path, scan, declaration = value
        bodies = _w3_direct_member_bodies(scan, declaration, pattern)
        if len(bodies) != 1:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    f"expected one reviewed {type_name}.{member_name} member, "
                    f"found {len(bodies)}",
                )
            )
            continue
        member_start, body_start, body_end = bodies[0]
        actual = _w3_compact_inventory(scan.masked[body_start:body_end])
        expected_scan = scan_swift(expected_source)
        expected = _w3_compact_inventory(expected_scan.masked)
        actual_literals = _w3_literal_inventory(
            scan,
            body_start,
            body_end,
        )
        expected_literals = tuple(
            expected_scan.source[literal.start:literal.end]
            for literal in sorted(
                expected_scan.strings,
                key=lambda value: value.start,
            )
        )
        if actual != expected or actual_literals != expected_literals:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    member_start,
                    f"reviewed {type_name}.{member_name} executable inventory changed",
                )
            )
    return violations


def _w3_direct_matches(
    scan: SwiftScan,
    declaration: TypeDeclaration,
    pattern: re.Pattern[str],
) -> list[re.Match[str]]:
    body_start = declaration.opening + 1
    return [
        match
        for match in pattern.finditer(
            scan.masked,
            body_start,
            declaration.closing,
        )
        if scan.masked[body_start:match.start()].count("{")
        == scan.masked[body_start:match.start()].count("}")
    ]


def _w3_production_direct_shape(
    root: Path,
    types: dict[str, tuple[Path, SwiftScan, TypeDeclaration]],
) -> list[Violation]:
    violations: list[Violation] = []
    property_pattern = re.compile(
        r"(?m)(?P<header>"
        r"(?:(?:public|package|internal|fileprivate|private|static|class|"
        r"nonisolated)(?:\s*\(\s*set\s*\))?\s+)*"
        r"(?:let|var)\s+`?[A-Za-z_][A-Za-z0-9_]*`?[^\n;]*?)"
        r"[ \t]*;?[ \t]*$"
    )
    callable_pattern = re.compile(
        r"\bfunc\s+(?P<function>[A-Za-z_][A-Za-z0-9_]*)\b|"
        r"(?<![A-Za-z0-9_.])(?P<initializer>init)\?\s*\("
        r"|(?<![A-Za-z0-9_.])(?P<plain_initializer>init)\s*\("
        r"|\b(?P<subscript>subscript)\s*\("
        r"|\b(?P<deinitializer>deinit)\b"
    )
    other_declaration_pattern = re.compile(
        r"\b(?:typealias|associatedtype|case)\b"
    )
    property_token_pattern = re.compile(r"\b(?:let|var)\b")
    callable_token_pattern = re.compile(
        r"\bfunc\b|(?<![A-Za-z0-9_.`])init[!?]?\s*\("
        r"|\bsubscript\b|\bdeinit\b"
    )
    nested_declaration_token_pattern = re.compile(
        r"\b(?:struct|class|enum|actor|protocol|extension|typealias|"
        r"associatedtype|case|operator|precedencegroup)\b"
    )
    for type_name, expected_properties in W3_DIRECT_PROPERTY_INVENTORIES.items():
        value = types.get(type_name)
        if value is None:
            continue
        path, scan, declaration = value
        property_matches = _w3_direct_matches(
            scan,
            declaration,
            property_pattern,
        )
        actual_properties = tuple(
            _w3_compact_inventory(match.group("header"))
            for match in property_matches
        )
        property_tokens = _w3_direct_matches(
            scan,
            declaration,
            property_token_pattern,
        )
        expected_callables = W3_DIRECT_CALLABLE_INVENTORIES[type_name]
        callable_matches = _w3_direct_matches(
            scan,
            declaration,
            callable_pattern,
        )
        actual_callables = tuple(
            match.group("function")
            or match.group("initializer")
            or match.group("plain_initializer")
            or match.group("subscript")
            or match.group("deinitializer")
            for match in callable_matches
        )
        callable_tokens = _w3_direct_matches(
            scan,
            declaration,
            callable_token_pattern,
        )
        other_declarations = _w3_direct_matches(
            scan,
            declaration,
            other_declaration_pattern,
        )
        nested_types = [
            nested
            for nested in type_declarations(scan)
            if declaration.opening < nested.start < declaration.closing
        ]
        nested_declaration_tokens = _w3_direct_matches(
            scan,
            declaration,
            nested_declaration_token_pattern,
        )
        if (
            actual_properties != expected_properties
            or len(property_tokens) != len(expected_properties)
            or actual_callables != expected_callables
            or len(callable_tokens) != len(expected_callables)
            or other_declarations
            or nested_types
            or nested_declaration_tokens
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    f"reviewed {type_name} direct property/callable shape changed",
                )
            )
    return violations


def _w3_production_limits(
    root: Path,
    types: dict[str, tuple[Path, SwiftScan, TypeDeclaration]],
) -> list[Violation]:
    violations: list[Violation] = []
    for (type_name, property_name), expected_literal in W3_PRODUCTION_LIMITS.items():
        value = types.get(type_name)
        if value is None:
            continue
        path, scan, declaration = value
        pattern = re.compile(
            rf"(?m)^[ \t]*static[ \t]+let[ \t]+{re.escape(property_name)}"
            rf"[ \t]*=[ \t]*(?P<value>[^\n;{{}}]+?)[ \t]*;?[ \t]*$"
        )
        matches = _w3_direct_matches(scan, declaration, pattern)
        exact = (
            len(matches) == 1
            and _w3_compact_inventory(matches[0].group("value"))
            == expected_literal
        )
        if not exact:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    f"{type_name}.{property_name} must be the literal "
                    f"{expected_literal}",
                )
            )
    return violations


W3_PRODUCTION_CALLS: tuple[
    tuple[str, re.Pattern[str], tuple[tuple[str, str, int], ...]], ...
] = (
    (
        "QuickLogInputAuthority.receiptItemThatMayBegin",
        re.compile(
            r"\bQuickLogInputAuthority\s*\.\s*receiptItemThatMayBegin\s*\("
        ),
        (
            (
                "App/MoneyUp/QuickLogEntryBody.swift",
                "item, isActive: isActive, "
                "cancelAssistance: { cancelOnDeviceAssistance() }",
                1,
            ),
        ),
    ),
    (
        "QuickLogInputAuthority.beginSmartFill",
        re.compile(r"\bQuickLogInputAuthority\s*\.\s*beginSmartFill\s*\("),
        (
            (
                W3_REVIEWED_ENTRY_PATH,
                "cancelReceipt: { cancelReceiptProcessing() }, "
                "cancelAssistance: { cancelOnDeviceAssistance() }",
                1,
            ),
        ),
    ),
    (
        "QuickLogInputAuthority.applyReceiptCategory",
        re.compile(
            r"\bQuickLogInputAuthority\s*\.\s*applyReceiptCategory\s*\("
        ),
        (
            (
                "App/MoneyUp/QuickLogEntryReceiptCandidates.swift",
                "invalidateAssistance: { "
                "invalidateOnDeviceCategoryForDeterministicChange() }",
                1,
            ),
        ),
    ),
    (
        "QuickLogPromptBoundary.normalized",
        re.compile(r"\bQuickLogPromptBoundary\s*\.\s*normalized\s*\("),
        (
            (
                W3_REVIEWED_REQUEST_PATH,
                "value, maximumScalarCount: "
                "QuickLogPromptBoundary.maximumContextScalarCount, "
                "maximumUTF8Count: QuickLogPromptBoundary.maximumContextUTF8Count",
                1,
            ),
            (
                W3_REVIEWED_REQUEST_PATH,
                "value, maximumScalarCount: "
                "QuickLogPromptBoundary.maximumChoiceScalarCount, "
                "maximumUTF8Count: QuickLogPromptBoundary.maximumChoiceUTF8Count",
                1,
            ),
        ),
    ),
    (
        "QuickLogPromptBoundary.contains",
        re.compile(r"\bQuickLogPromptBoundary\s*\.\s*contains\s*\("),
        ((W3_REVIEWED_REQUEST_PATH, "prompt", 1),),
    ),
    (
        "QuickLogPromptComponent.init",
        re.compile(r"\bQuickLogPromptComponent\s*\("),
        ((W3_REVIEWED_REQUEST_PATH, "text: $0", 2),),
    ),
    (
        "QuickLogPromptComponent.context",
        re.compile(r"\bQuickLogPromptComponent\s*\.\s*context\s*\("),
        (
            (W3_REVIEWED_REQUEST_PATH, "plan.context", 1),
            (W3_REVIEWED_REQUEST_PATH, "context", 1),
        ),
    ),
    (
        "QuickLogPromptComponent.choice",
        re.compile(r"\bQuickLogPromptComponent\s*\.\s*choice\s*\("),
        (
            (W3_REVIEWED_REQUEST_PATH, "$0.label", 2),
            (W3_REVIEWED_REQUEST_PATH, "account.name", 1),
            (W3_REVIEWED_REQUEST_PATH, "choice.label", 1),
        ),
    ),
    (
        "QuickLogOrdinalRequest.init",
        re.compile(r"\bQuickLogOrdinalRequest\s*\("),
        (
            (
                W3_REVIEWED_REQUEST_PATH,
                "context: context, firstChoices: firstChoices, "
                "secondChoices: secondChoices",
                1,
            ),
        ),
    ),
    (
        "QuickLogOrdinalRequest.make",
        re.compile(r"\bQuickLogOrdinalRequest\s*\.\s*make\s*\("),
        ((W3_REVIEWED_REQUEST_PATH, "plan: plan", 1),),
    ),
    (
        "QuickLogAssistanceChoice.init",
        re.compile(r"\bQuickLogAssistanceChoice\s*\("),
        (
            (
                W3_REVIEWED_REQUEST_PATH,
                "id: account.id, label: $0.text",
                1,
            ),
            (
                W3_REVIEWED_REQUEST_PATH,
                "id: choice.id, label: $0.text",
                1,
            ),
        ),
    ),
    (
        "QuickLogAssistancePlan.init",
        re.compile(r"\bQuickLogAssistancePlan\s*\("),
        (
            (
                W3_REVIEWED_REQUEST_PATH,
                "context: context, accountChoices: accountChoices, "
                "categoryChoices: categoryChoices",
                1,
            ),
        ),
    ),
    (
        "QuickLogAssistancePlan.make",
        re.compile(r"\bQuickLogAssistancePlan\s*\.\s*make\s*\("),
        (
            (
                "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift",
                "parsed: parsed, accounts: accounts, categories: categorySnapshot, "
                "accountFieldWasEdited: baseline.account.wasEdited, "
                "categoryFieldWasEdited: baseline.category.wasEdited",
                1,
            ),
        ),
    ),
    (
        "QuickLogOrdinalPair.init",
        re.compile(r"\bQuickLogOrdinalPair\s*\("),
        (
            (
                W3_REVIEWED_MODEL_PATH,
                "firstOrdinal: response.content.firstChoiceOrdinal, "
                "secondOrdinal: response.content.secondChoiceOrdinal",
                1,
            ),
        ),
    ),
    (
        "QuickLogAssistanceResolver.resolve",
        re.compile(r"\bQuickLogAssistanceResolver\s*\.\s*resolve\s*\("),
        (
            (
                W3_REVIEWED_REQUEST_PATH,
                "plan: plan, selector: selector",
                1,
            ),
        ),
    ),
    (
        "QuickLogOrdinalSelector.select",
        re.compile(r"(?<![A-Za-z0-9_])selector\s*\.\s*select\s*\("),
        ((W3_REVIEWED_REQUEST_PATH, "request", 1),),
    ),
    (
        "QuickLogAssistanceCoordinator.resolve",
        re.compile(
            r"\bonDeviceAssistanceCoordinator\s*\.\s*resolve\s*\("
        ),
        ((W3_REVIEWED_ENTRY_ASSISTANCE_PATH, "enabled: enabled", 1),),
    ),
    (
        "NaturalLanguageEntryParser.parse",
        re.compile(r"\bNaturalLanguageEntryParser\s*\.\s*parse\s*\("),
        (
            (
                W3_REVIEWED_ENTRY_PATH,
                "smartText, accounts: model.accounts, "
                "now: model.currentDateForUserAction(), "
                "calendar: model.reportingCalendar, "
                "prefersDayFirst: Self.localePrefersDayFirst",
                1,
            ),
        ),
    ),
    (
        "ParsedNaturalLanguageEntry.init",
        re.compile(r"\bParsedNaturalLanguageEntry\s*\("),
        (
            (
                W3_REVIEWED_PARSER_PATH,
                "draft: draft, context: assistanceContext( "
                "from: remainder, currencyCodes: currencyCodes, "
                "localNames: accounts.map(\\.name) )",
                1,
            ),
        ),
    ),
    (
        "QuickLogAssistancePrompt.text",
        re.compile(r"\bQuickLogAssistancePrompt\s*\.\s*text\s*\("),
        ((W3_REVIEWED_MODEL_PATH, "for: request", 1),),
    ),
    (
        "QuickLogOnDeviceOrdinalModel.select",
        re.compile(r"\bQuickLogOnDeviceOrdinalModel\s*\.\s*select\s*\("),
        ((W3_REVIEWED_REQUEST_PATH, "request: request", 1),),
    ),
)


def _w3_production_call_inventory(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    for call_name, pattern, expected_values in W3_PRODUCTION_CALLS:
        actual = Counter(
            (
                relative_path(path, root),
                _w3_compact_inventory(arguments),
            )
            for path, _, _, arguments in _w3_call_sites(scans, pattern)
        )
        expected = Counter(
            {
                (path, _w3_compact_inventory(arguments)): count
                for path, arguments, count in expected_values
            }
        )
        if actual != expected:
            violations.append(
                _w3_boundary_violation(
                    root,
                    None,
                    None,
                    0,
                    f"reviewed {call_name} production call inventory changed",
                )
            )
    return violations


def _w3_parser_provenance(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    entry_path = root / W3_REVIEWED_ENTRY_PATH
    entry_scan = scans.get(entry_path)
    if entry_scan is None:
        return [
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"reviewed deterministic parser entry is missing: "
                f"{W3_REVIEWED_ENTRY_PATH}",
            )
        ]
    apply_body = _w3_named_function_body(entry_scan, "applyTypedPhrase")
    if apply_body is None:
        violations.append(
            _w3_boundary_violation(
                root,
                entry_path,
                entry_scan,
                0,
                "reviewed applyTypedPhrase parser entry is missing",
            )
        )
    else:
        start, end = apply_body
        body = entry_scan.masked[start:end]
        parser_binding = re.compile(
            r"\blet\s+parsed\s*=\s*NaturalLanguageEntryParser\s*\.\s*parse\s*\("
        )
        assistance_call = re.compile(
            r"\bstartOnDeviceAssistance\s*\(\s*for\s*:\s*parsed\s*\)"
        )
        draft_application = re.compile(r"\bapply\s*\(\s*parsed\s*\.\s*draft\s*\)")
        if (
            len(parser_binding.findall(body)) != 1
            or len(assistance_call.findall(body)) != 1
            or len(draft_application.findall(body)) != 1
            or len(re.findall(r"\b(?:let|var)\s+parsed\b", body)) != 1
            or len(re.findall(r"\bparsed\b", body)) != 3
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    entry_path,
                    entry_scan,
                    start,
                    "on-device assistance must receive the sole immutable output "
                    "of NaturalLanguageEntryParser.parse",
                )
            )

    assistance_path = root / W3_REVIEWED_ENTRY_ASSISTANCE_PATH
    assistance_scan = scans.get(assistance_path)
    if assistance_scan is None:
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"reviewed assistance entry is missing: "
                f"{W3_REVIEWED_ENTRY_ASSISTANCE_PATH}",
            )
        )
        return violations
    signature = re.compile(
        r"\bfunc\s+startOnDeviceAssistance\s*\(\s*for\s+parsed\s*:"
        r"\s*ParsedNaturalLanguageEntry\s*\)\s*\{"
    )
    declarations = list(signature.finditer(assistance_scan.masked))
    if len(declarations) != 1:
        violations.append(
            _w3_boundary_violation(
                root,
                assistance_path,
                assistance_scan,
                0,
                "reviewed assistance entry must accept one deterministic parsed value",
            )
        )
    else:
        opening = declarations[0].end() - 1
        closing = find_matching(assistance_scan.masked, opening)
        body = (
            assistance_scan.masked[opening + 1:closing]
            if closing is not None else ""
        )
        plan_call = re.compile(
            r"\bQuickLogAssistancePlan\s*\.\s*make\s*\("
            r"\s*parsed\s*:\s*parsed\s*,"
        )
        if (
            len(plan_call.findall(body)) != 1
            or re.search(r"\b(?:let|var)\s+parsed\b", body) is not None
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    assistance_path,
                    assistance_scan,
                    declarations[0].start(),
                    "reviewed plan must consume the unchanged parsed parameter",
                )
            )
    return violations


def _w3_production_compile_shape(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    directive_counts: Counter[str] = Counter()
    for path, scan in scans.items():
        offset = 0
        for line in scan.masked.splitlines(keepends=True):
            directive = re.match(r"^[ \t]*#(?:if|elseif)\b(.*)$", line)
            if directive is not None and "FoundationModels" in directive.group(1):
                condition = re.sub(r"\s+", "", directive.group(1))
                if condition != "canImport(FoundationModels)":
                    violations.append(
                        Violation(
                            relative_path(path, root),
                            line_number(scan.source, offset),
                            "w3-compile-gate",
                            "production W3 branches must use exactly "
                            "#if canImport(FoundationModels)",
                        )
                    )
                else:
                    directive_counts[relative_path(path, root)] += 1
            offset += len(line)
    expected = Counter(
        {
            W3_REVIEWED_MODEL_PATH: 1,
            W3_REVIEWED_REQUEST_PATH: 1,
        }
    )
    if directive_counts != expected:
        violations.append(
            Violation(
                "<repository>",
                1,
                "w3-compile-gate",
                "production W3 must have one exact compile branch in each "
                "canonical request and model source",
            )
        )
    return violations


def _w3_production_shape(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    sentinel_path = root / W3_PRODUCTION_SENTINEL_PATH
    sentinel_scan = scans.get(sentinel_path)
    if (
        sentinel_scan is None
        or W3_PRODUCTION_SENTINEL.search(sentinel_scan.masked) is None
    ):
        violations.append(
            _w3_boundary_violation(
                root,
                sentinel_path if sentinel_scan is not None else None,
                sentinel_scan,
                0,
                "production W3 opt-in sentinel is missing from "
                f"{W3_PRODUCTION_SENTINEL_PATH}",
            )
        )
    model_path = root / W3_REVIEWED_MODEL_PATH
    request_path = root / W3_REVIEWED_REQUEST_PATH
    for path, relative in (
        (model_path, W3_REVIEWED_MODEL_PATH),
        (request_path, W3_REVIEWED_REQUEST_PATH),
    ):
        if path not in scans:
            violations.append(
                _w3_boundary_violation(
                    root,
                    None,
                    None,
                    0,
                    f"canonical production W3 source is missing: {relative}",
                )
            )

    imports = [
        (path, scan, offset)
        for path, scan in scans.items()
        for module, offset in import_modules(scan)
        if module == "FoundationModels"
    ]
    model_scan = scans.get(model_path)
    plain_imports = (
        re.findall(
            r"(?m)^[ \t]*import[ \t]+FoundationModels[ \t]*$",
            model_scan.masked,
        )
        if model_scan is not None else []
    )
    if (
        len(imports) != 1
        or imports[0][0] != model_path
        or len(plain_imports) != 1
    ):
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                "FoundationModels must have one canonical production import in "
                f"{W3_REVIEWED_MODEL_PATH}",
            )
        )

    types, type_violations = _w3_named_production_types(root, scans)
    violations.extend(type_violations)
    selection = types.get("LocalOrdinalSelection")
    if selection is not None:
        path, scan, declaration = selection
        expected_body = _w3_expected_inventory(
            r"""
            @Guide(.range(0...15))
            var firstChoiceOrdinal: Int
            @Guide(.range(0...15))
            var secondChoiceOrdinal: Int
            """
        )
        actual_body = _w3_compact_inventory(
            scan.masked[declaration.opening + 1:declaration.closing]
        )
        declaration_line_start = scan.masked.rfind(
            "\n", 0, declaration.start
        ) + 1
        declaration_line = scan.masked[
            declaration_line_start:declaration.opening
        ]
        if (
            not declaration.generable
            or re.fullmatch(
                r"\s*private\s+struct\s+LocalOrdinalSelection\s*",
                declaration_line,
            ) is None
            or actual_body != expected_body
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    declaration.start,
                    "LocalOrdinalSelection must remain the reviewed private "
                    "two-ordinal @Generable shape",
                )
            )

    violations.extend(_w3_production_top_level_inventories(root, scans))
    violations.extend(_w3_production_type_inventories(root, types))
    violations.extend(_w3_path_type_inventories(root, scans))
    violations.extend(_w3_production_type_references(root, scans))
    violations.extend(_w3_profile_opt_in_inventory(root, scans))
    violations.extend(_w3_quick_log_state_declaration_inventory(root, scans))
    violations.extend(_w3_production_limits(root, types))
    violations.extend(_w3_production_direct_shape(root, types))
    violations.extend(_w3_production_member_inventories(root, types))
    violations.extend(_w3_source_function_inventories(root, scans))
    violations.extend(_w3_production_call_inventory(root, scans))
    violations.extend(_w3_parser_provenance(root, scans))
    violations.extend(_w3_production_compile_shape(root, scans))
    return violations


def _w3_named_function_body(
    scan: SwiftScan,
    name: str,
) -> tuple[int, int] | None:
    declaration = re.search(
        rf"\bfunc\s+{re.escape(name)}\b[^{{}};]*\{{",
        scan.masked,
        re.DOTALL,
    )
    if declaration is None:
        return None
    opening = declaration.end() - 1
    closing = find_matching(scan.masked, opening)
    return None if closing is None else (opening + 1, closing)


def _w3_prompt_builder_inventory(
    root: Path,
    path: Path,
    scan: SwiftScan,
) -> list[Violation]:
    violations: list[Violation] = []
    expected_bodies = {
        "text": (
            "let firstChoices = numbered(request.firstChoices) "
            "let secondChoices = numbered(request.secondChoices) "
            "let prompt = request.context.text firstChoices secondChoices "
            "return QuickLogPromptBoundary.contains(prompt) "
            "? prompt : nil"
        ),
        "numbered": (
            "guard !choices.isEmpty else { return } "
            "return choices.enumerated().map { index, choice in "
            "index choice.text }.joined(separator: )"
        ),
    }
    ranges: list[tuple[int, int]] = []
    for name, expected in expected_bodies.items():
        body_range = _w3_named_function_body(scan, name)
        if body_range is None:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    0,
                    f"reviewed prompt {name} function is missing",
                )
            )
            continue
        ranges.append(body_range)
        start, end = body_range
        inventory = re.sub(r"\s+", " ", scan.masked[start:end]).strip()
        if inventory != expected:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    start,
                    f"reviewed prompt {name} inventory contains an ambient source",
                )
            )
    if ranges:
        raw = "\n".join(scan.source[start:end] for start, end in ranges)
        interpolations = sorted(
            re.sub(r"\s+", "", match.group(1))
            for match in re.finditer(r"\\\(([^()]*)\)", raw)
        )
        expected_interpolations = sorted(
            (
                "request.context.text",
                "firstChoices",
                "secondChoices",
                "index",
                "choice.text",
            )
        )
        if interpolations != expected_interpolations:
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    ranges[0][0],
                    "prompt interpolation inventory must contain only typed context, "
                    "typed numbered choices, and local ordinals",
                )
            )
    return violations


def _w3_reviewed_input_boundary(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    model_path = root / W3_REVIEWED_MODEL_PATH
    request_path = root / W3_REVIEWED_REQUEST_PATH
    model_scan = scans.get(model_path)
    request_scan = scans.get(request_path)
    if model_scan is None or request_scan is None:
        return [
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                "reviewed typed request and model files must both exist",
            )
        ]

    responses = _w3_call_sites(
        scans,
        re.compile(W3_RESPONSE_CALL_NAME + r"\s*\("),
    )
    if len(responses) != 1:
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"expected one reviewed model response call, found {len(responses)}",
            )
        )
    for path, scan, match, arguments in responses:
        to_argument = re.search(
            r"(?:\A|,)\s*to\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|\Z)",
            arguments,
        )
        if (
            path != model_path
            or "streamResponse" in match.group(0)
            or to_argument is None
            or to_argument.group(1) != "reviewedPrompt"
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    match.start(),
                    "model response must be the sole reviewedPrompt call in "
                    f"{W3_REVIEWED_MODEL_PATH}",
                )
            )

    typed_select = re.compile(
        r"\bstatic\s+func\s+select\s*\(\s*"
        r"request\s*:\s*QuickLogOrdinalRequest\s*\)"
    )
    if typed_select.search(model_scan.masked) is None:
        violations.append(
            _w3_boundary_violation(
                root,
                model_path,
                model_scan,
                0,
                "model seam must accept only QuickLogOrdinalRequest",
            )
        )
    prompt_binding = re.compile(
        r"\bguard\s+let\s+reviewedPrompt\s*=\s*"
        r"QuickLogAssistancePrompt\s*\.\s*text\s*\(\s*"
        r"for\s*:\s*request\s*\)\s*else\s*\{\s*return\s+nil\s*\}"
    )
    if prompt_binding.search(model_scan.masked) is None:
        violations.append(
            _w3_boundary_violation(
                root,
                model_path,
                model_scan,
                0,
                "reviewedPrompt must be built only from the typed request",
            )
        )

    selector_calls = _w3_call_sites(
        scans,
        re.compile(r"\bQuickLogOnDeviceOrdinalModel\s*\.\s*select\s*\("),
    )
    if len(selector_calls) != 1:
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"expected one typed model selector call, found {len(selector_calls)}",
            )
        )
    for path, scan, match, arguments in selector_calls:
        if (
            path != request_path
            or re.fullmatch(r"\s*request\s*:\s*request\s*", arguments) is None
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    match.start(),
                    "model selector may receive only the reviewed request variable",
                )
            )

    prompt_calls = _w3_call_sites(
        scans,
        re.compile(r"\bQuickLogAssistancePrompt\s*\.\s*text\s*\("),
    )
    if len(prompt_calls) != 1:
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"expected one reviewed prompt construction, found {len(prompt_calls)}",
            )
        )
    for path, scan, match, arguments in prompt_calls:
        if (
            path != model_path
            or re.fullmatch(r"\s*for\s*:\s*request\s*", arguments) is None
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    match.start(),
                    "prompt construction may consume only the typed request",
                )
            )

    request_calls = _w3_call_sites(
        scans,
        re.compile(r"\bQuickLogOrdinalRequest\s*\("),
    )
    expected_request_arguments = re.compile(
        r"\s*context\s*:\s*context\s*,\s*"
        r"firstChoices\s*:\s*firstChoices\s*,\s*"
        r"secondChoices\s*:\s*secondChoices\s*"
    )
    if len(request_calls) != 1:
        violations.append(
            _w3_boundary_violation(
                root,
                None,
                None,
                0,
                f"expected one private typed request construction, found {len(request_calls)}",
            )
        )
    for path, scan, match, arguments in request_calls:
        if (
            path != request_path
            or expected_request_arguments.fullmatch(arguments) is None
        ):
            violations.append(
                _w3_boundary_violation(
                    root,
                    path,
                    scan,
                    match.start(),
                    "typed request construction must use only normalized local components",
                )
            )
    required_request_patterns = (
        r"\bprivate\s+init\s*\(\s*context\s*:\s*QuickLogPromptComponent",
        r"QuickLogPromptComponent\s*\.\s*context\s*\(\s*plan\s*\.\s*context\s*\)",
        r"QuickLogPromptComponent\s*\.\s*choice\s*\(\s*\$0\s*\.\s*label\s*\)",
    )
    expected_counts = (1, 1, 2)
    for pattern, expected_count in zip(required_request_patterns, expected_counts):
        count = len(re.findall(pattern, request_scan.masked))
        if count != expected_count:
            violations.append(
                _w3_boundary_violation(
                    root,
                    request_path,
                    request_scan,
                    0,
                    "typed request provenance changed: expected "
                    f"{expected_count} occurrence(s) of {pattern!r}, found {count}",
                )
            )

    reviewed_bodies: list[tuple[Path, SwiftScan, int, int]] = []
    for path, scan, declaration_name in (
        (request_path, request_scan, "QuickLogAssistancePrompt"),
        (model_path, model_scan, "QuickLogOnDeviceOrdinalModel"),
    ):
        reviewed_bodies.extend(
            (path, scan, declaration.opening + 1, declaration.closing)
            for declaration in type_declarations(scan)
            if declaration.name == declaration_name
        )
    for path, scan, start, end in reviewed_bodies:
        for match in re.finditer(r"\b[A-Za-z_][A-Za-z0-9_]*\b", scan.masked[start:end]):
            tokens = _identifier_tokens(match.group(0))
            forbidden = sorted(tokens & W3_FORBIDDEN_INPUT_TOKENS)
            if forbidden:
                violations.append(
                    _w3_boundary_violation(
                        root,
                        path,
                        scan,
                        start + match.start(),
                        "reviewed model input path contains forbidden token(s): "
                        + ", ".join(forbidden),
                    )
                )
    violations.extend(
        _w3_prompt_builder_inventory(root, request_path, request_scan)
    )
    return violations


def _w3_accessible_suggestion_actions(
    root: Path,
    scans: dict[Path, SwiftScan],
) -> list[Violation]:
    violations: list[Violation] = []
    requirements = (
        (
            "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift",
            "onDeviceAssistanceRow",
            re.compile(
                r"\bprivate\s+func\s+onDeviceAssistanceRow\s*\("
                r"\s*title\s*:\s*String\s*,\s*value\s*:\s*String\s*,"
                r"\s*isApplied\s*:\s*Bool\s*,"
                r"\s*useAccessibilityLabel\s*:\s*String\s*,"
                r"\s*apply\s*:\s*@escaping\s*\(\s*\)\s*->\s*Void"
                r"\s*\)\s*->\s*some\s+View\s*\{",
                re.DOTALL,
            ),
            "9f8684fb8fcf76932338b18d483bf6c1471deb70fcee2d939dd9a54485daebff",
            "onDeviceAssistanceCard",
            re.compile(
                r"\bfunc\s+onDeviceAssistanceCard\s*\(\s*_\s+presentation\s*:"
                r"\s*QuickLogAssistancePresentation\s*\)\s*->"
                r"\s*some\s+View\s*\{"
            ),
            "d12f71f8f7d492375824191a599c6e2bb6843f3fe0e70345f3d4ed774ae3d4b6",
        ),
        (
            "App/MoneyUp/QuickLogEntryCaptureSuggestions.swift",
            "captureSuggestionRow",
            re.compile(
                r"\bprivate\s+func\s+captureSuggestionRow\s*\("
                r"\s*title\s*:\s*String\s*,"
                r"\s*account\s*:\s*LedgerAccount\s*,"
                r"\s*suggestion\s*:\s*CaptureFieldSuggestion\s*,"
                r"\s*isApplied\s*:\s*Bool\s*,"
                r"\s*useAccessibilityLabel\s*:\s*String\s*,"
                r"\s*apply\s*:\s*@escaping\s*\(\s*\)\s*->\s*Void"
                r"\s*\)\s*->\s*some\s+View\s*\{",
                re.DOTALL,
            ),
            "a93e4dbff41a990517e592136526a0952599c7a453c533d8e4b0d13c7c4b22ee",
            "captureSuggestions",
            re.compile(
                r"\bfunc\s+captureSuggestions\s*\(\s*_\s+result\s*:"
                r"\s*CaptureSuggestionResult\s*\)\s*->\s*some\s+View\s*\{"
            ),
            "730096fb08938c2a4d1ebfcdb37e1077acc336d2cc69b64572dcdb7dd6ab0aa9",
        ),
    )
    use_literal = "quick_log.use_suggestion"
    expected_literal_inventory = {
        relative: 1 for relative, *_ in requirements
    }
    actual_literal_inventory: Counter[str] = Counter()
    first_literal_offsets: dict[str, int] = {}
    for path, scan in scans.items():
        relative = relative_path(path, root)
        offsets = [
            literal.start
            for literal in scan.strings
            if literal.value == use_literal
        ]
        if offsets:
            actual_literal_inventory[relative] = len(offsets)
            first_literal_offsets[relative] = offsets[0]
    for relative in sorted(
        set(expected_literal_inventory) | set(actual_literal_inventory)
    ):
        expected_count = expected_literal_inventory.get(relative, 0)
        actual_count = actual_literal_inventory.get(relative, 0)
        if actual_count == expected_count:
            continue
        path = root / relative
        scan = scans.get(path)
        violations.append(
            Violation(
                relative,
                line_number(
                    scan.source,
                    first_literal_offsets.get(relative, 0),
                )
                if scan is not None else 1,
                "w3-accessibility",
                "global visible Use action inventory changed: expected "
                f"{expected_count} {use_literal!r} literal(s), found "
                f"{actual_count}",
            )
        )
    keys = (
        "quick_log.use_account_accessibility_format",
        "quick_log.use_category_accessibility_format",
    )
    for (
        relative,
        function_name,
        signature,
        expected_digest,
        caller_name,
        caller_signature,
        expected_caller_digest,
    ) in requirements:
        path = root / relative
        scan = scans.get(path)
        if scan is None:
            violations.append(
                Violation(
                    relative,
                    1,
                    "w3-accessibility",
                    "reviewed suggestion action source is missing",
                )
            )
            continue
        extensions = [
            declaration
            for declaration in type_declarations(scan)
            if declaration.kind == "extension"
            and declaration.name == "QuickLogEntryView"
            and scan.masked[:declaration.start].count("{")
            == scan.masked[:declaration.start].count("}")
        ]
        declarations = (
            _w3_direct_member_bodies(scan, extensions[0], signature)
            if len(extensions) == 1 else []
        )
        caller_declarations = (
            _w3_direct_member_bodies(scan, extensions[0], caller_signature)
            if len(extensions) == 1 else []
        )
        if (
            len(declarations) != 1
            or len(caller_declarations) != 1
            or _w3_executable_digest(
                scan,
                declarations[0][1],
                declarations[0][2],
            ) != expected_digest
            or _w3_executable_digest(
                scan,
                caller_declarations[0][1],
                caller_declarations[0][2],
            ) != expected_caller_digest
        ):
            violations.append(
                Violation(
                    relative,
                    1,
                    "w3-accessibility",
                    f"expected exact reviewed {caller_name}/{function_name} "
                    "call and action inventories",
                )
            )
            continue
        _, body_start, body_end = declarations[0]
        body = scan.masked[body_start:body_end]
        owned_chain = re.compile(
            r"\bButton\s*\(\s+,\s*action\s*:\s*apply\s*\)"
            r"\s*\.\s*buttonStyle\s*\(\s*\.\s*borderless\s*\)"
            r"\s*\.\s*accessibilityLabel\s*\(\s*Text\s*\("
            r"\s*useAccessibilityLabel\s*\)\s*\)"
        )
        chains = list(owned_chain.finditer(body))
        button_literals = [
            literal
            for literal in scan.strings
            if body_start <= literal.start < body_end
            and literal.value == "quick_log.use_suggestion"
        ]
        owns_literal = (
            len(chains) == 1
            and len(button_literals) == 1
            and body_start + chains[0].start()
            < button_literals[0].start
            < button_literals[0].end
            < body_start + chains[0].end()
        )
        if (
            not owns_literal
            or len(re.findall(r"\bButton\s*\(", body)) != 1
            or len(re.findall(r"\.\s*accessibilityLabel\s*\(", body)) != 1
        ):
            violations.append(
                Violation(
                    relative,
                    line_number(scan.source, body_start),
                    "w3-accessibility",
                    "each visible Use action must own a contextual accessibility label",
                )
            )
        for key in keys:
            if scan.source.count(f'AppLocalization.string(\n                            "{key}"') != 1:
                violations.append(
                    Violation(
                        relative,
                        1,
                        "w3-accessibility",
                        f"expected one contextual localization use for {key}",
                    )
                )
    return violations


def validate_w3_foundation_models(root: Path) -> list[Violation]:
    paths = swift_sources(root)
    scans = {
        path: scan_swift(path.read_text(encoding="utf-8")) for path in paths
    }
    production_enabled = _w3_production_is_enabled(root, scans)
    importing = {
        path
        for path, scan in scans.items()
        if "FoundationModels" in {module for module, _ in import_modules(scan)}
    }
    if not importing and not production_enabled:
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
    if production_enabled:
        violations.extend(_w3_production_shape(root, scans))
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
                re.match(W3_RESPONSE_CALL_NAME + r"\s*\(", match.group(0))
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
    if production_enabled:
        violations.extend(_w3_reviewed_input_boundary(root, scans))
        violations.extend(_w3_accessible_suggestion_actions(root, scans))
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
