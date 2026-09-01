#!/usr/bin/env python3
"""Enforce scoped, accessible ownership of user-visible error messages."""

from __future__ import annotations

from dataclasses import dataclass
import re
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ROOT / "App" / "MoneyUp"
PROJECT_FILE = ROOT / "project.yml"

DECLARATION = re.compile(
    r"\b(?P<kind>struct|class|enum|extension)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_.]*)[^{};]*\{"
)
FUNCTION = re.compile(
    r"\bfunc\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)[^{};]*\{"
)
VIEW_PROPERTY = re.compile(
    r"\bvar\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*some\s+View\s*\{"
)
SAFE_MESSAGE = re.compile(r"\bsafeUserMessage\s*\(")
OPERATION_ALERT = re.compile(
    r"\.moneyUpOperationErrorAlert\s*\(\s*message\s*:\s*"
    r"\$(?P<target>[A-Za-z_][A-Za-z0-9_]*)\s*\)"
)
FIELD_ASSOCIATION = re.compile(
    r"\.moneyUpFieldValidation\s*\(\s*"
    r"(?P<target>[A-Za-z_][A-Za-z0-9_.]*)\s*\)"
)
FIELD_ERROR = re.compile(
    r"\bMoneyUpFieldError\s*\(\s*message\s*:\s*"
    r"(?P<target>[A-Za-z_][A-Za-z0-9_.]*)\s*\)"
)
IF_LET = re.compile(
    r"\bif\s+let\s+(?P<target>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*=\s*[^{}]+)?\s*\{"
)
RED_STYLE = re.compile(r"\.foregroundStyle\s*\(\s*\.red\s*\)")
INPUT_VIEW_NAMES = frozenset({"DatePicker", "SecureField", "TextEditor", "TextField"})
RETRY_LABEL = re.compile(
    r'\bButton\s*\(\s*"(?:action\.retry|action\.try_again|'
    r'recovery\.key_cliff\.retry)"\s*\)\s*\{'
)


@dataclass(frozen=True)
class Scope:
    name: str
    start: int
    body_start: int
    end: int


@dataclass
class SwiftSource:
    path: Path
    source: str
    masked: str
    braces: dict[int, int]
    parentheses: dict[int, int]
    type_scopes: list[Scope]
    function_scopes: list[Scope]
    view_scopes: list[Scope]

    @classmethod
    def parse(cls, path: Path, source: str) -> SwiftSource:
        masked = mask_comments_and_strings(source)
        braces = delimiter_pairs(masked, "{", "}")
        parentheses = delimiter_pairs(masked, "(", ")")
        raw_type_scopes = extract_scopes(masked, braces, DECLARATION)
        return cls(
            path=path,
            source=source,
            masked=masked,
            braces=braces,
            parentheses=parentheses,
            type_scopes=qualify_type_scopes(raw_type_scopes),
            function_scopes=extract_scopes(masked, braces, FUNCTION),
            view_scopes=extract_scopes(masked, braces, VIEW_PROPERTY),
        )

    def owner_at(self, position: int) -> str | None:
        candidates = [
            scope for scope in self.type_scopes
            if scope.body_start < position < scope.end
        ]
        if not candidates:
            return None
        return min(candidates, key=lambda scope: scope.end - scope.start).name

    def function_at(self, position: int) -> str | None:
        candidates = [
            scope for scope in self.function_scopes
            if scope.body_start < position < scope.end
        ]
        if not candidates:
            return None
        return min(candidates, key=lambda scope: scope.end - scope.start).name

    def view_scope_at(self, position: int) -> Scope | None:
        candidates = [
            scope for scope in self.view_scopes
            if scope.body_start < position < scope.end
        ]
        if not candidates:
            return None
        return min(candidates, key=lambda scope: scope.end - scope.start)

    def line(self, position: int) -> int:
        return self.source.count("\n", 0, position) + 1


def mask_comments_and_strings(source: str) -> str:
    """Preserve offsets/newlines while hiding Swift comments and literals."""
    result = list(source)
    index = 0
    block_depth = 0
    state = "code"
    while index < len(source):
        if state == "line-comment":
            if source[index] == "\n":
                state = "code"
            else:
                result[index] = " "
            index += 1
            continue
        if state == "block-comment":
            if source.startswith("/*", index):
                result[index:index + 2] = "  "
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                result[index:index + 2] = "  "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                if source[index] != "\n":
                    result[index] = " "
                index += 1
            continue
        if state in {"string", "triple-string"}:
            terminator = '"""' if state == "triple-string" else '"'
            if source.startswith(terminator, index):
                for offset in range(len(terminator)):
                    result[index + offset] = " "
                index += len(terminator)
                state = "code"
            elif state == "string" and source[index] == "\\":
                result[index] = " "
                if index + 1 < len(source):
                    if source[index + 1] != "\n":
                        result[index + 1] = " "
                    index += 2
                else:
                    index += 1
            else:
                if source[index] != "\n":
                    result[index] = " "
                index += 1
            continue

        if source.startswith("//", index):
            result[index:index + 2] = "  "
            index += 2
            state = "line-comment"
        elif source.startswith("/*", index):
            result[index:index + 2] = "  "
            index += 2
            block_depth = 1
            state = "block-comment"
        elif source.startswith('"""', index):
            result[index:index + 3] = "   "
            index += 3
            state = "triple-string"
        elif source[index] == '"':
            result[index] = " "
            index += 1
            state = "string"
        else:
            index += 1
    return "".join(result)


def delimiter_pairs(source: str, opening: str, closing: str) -> dict[int, int]:
    stack: list[int] = []
    pairs: dict[int, int] = {}
    for index, character in enumerate(source):
        if character == opening:
            stack.append(index)
        elif character == closing and stack:
            pairs[stack.pop()] = index
    return pairs


def extract_scopes(
    source: str,
    braces: dict[int, int],
    pattern: re.Pattern[str],
) -> list[Scope]:
    scopes: list[Scope] = []
    for match in pattern.finditer(source):
        opening = source.rfind("{", match.start(), match.end())
        closing = braces.get(opening)
        if closing is None:
            continue
        scopes.append(
            Scope(
                name=match.group("name"),
                start=match.start(),
                body_start=opening,
                end=closing,
            )
        )
    return scopes


def qualify_type_scopes(scopes: list[Scope]) -> list[Scope]:
    """Keep nested Swift owners distinct while merging top-level extensions."""
    qualified: list[Scope] = []
    for scope in sorted(scopes, key=lambda item: (item.start, -item.end)):
        parents = [
            candidate for candidate in qualified
            if candidate.body_start < scope.start < scope.end < candidate.end
        ]
        parent = min(parents, key=lambda item: item.end - item.start) if parents else None
        explicit_name = scope.name
        if parent is not None and "." not in explicit_name:
            explicit_name = f"{parent.name}.{explicit_name}"
        qualified.append(
            Scope(
                name=explicit_name,
                start=scope.start,
                body_start=scope.body_start,
                end=scope.end,
            )
        )
    return qualified


def source_label(document: SwiftSource, position: int) -> str:
    try:
        relative = document.path.relative_to(ROOT)
    except ValueError:
        relative = document.path
    return f"{relative}:{document.line(position)}"


def direct_assignment_target(document: SwiftSource, position: int) -> str | None:
    prefix = document.masked[max(0, position - 180):position]
    assignment = re.search(
        r"\b(?P<target>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*$",
        prefix,
    )
    return assignment.group("target") if assignment else None


def collect_safe_assignment_publishers(
    documents: list[SwiftSource],
) -> dict[tuple[str, str], set[str]]:
    publishers: dict[tuple[str, str], set[str]] = {}
    for document in documents:
        for match in SAFE_MESSAGE.finditer(document.masked):
            owner = document.owner_at(match.start())
            function = document.function_at(match.start())
            target = direct_assignment_target(document, match.start())
            if owner is not None and function is not None and target is not None:
                publishers.setdefault((owner, target), set()).add(function)
    return publishers


def reachable_view_scopes(
    documents: list[SwiftSource],
) -> dict[str, set[str]]:
    """Follow same-owner computed-view references outward from `body`."""
    definitions: dict[str, dict[str, list[str]]] = {}
    for document in documents:
        for scope in document.view_scopes:
            owner = document.owner_at(scope.body_start + 1)
            if owner is None:
                continue
            definitions.setdefault(owner, {}).setdefault(scope.name, []).append(
                document.masked[scope.body_start + 1:scope.end]
            )

    reachable: dict[str, set[str]] = {}
    for owner, properties in definitions.items():
        if "body" not in properties:
            continue
        owner_reachable = {"body"}
        changed = True
        while changed:
            changed = False
            active_source = "\n".join(
                body
                for name in owner_reachable
                for body in properties.get(name, [])
            )
            for name in properties:
                if name in owner_reachable:
                    continue
                if re.search(rf"\b{re.escape(name)}\b", active_source):
                    owner_reachable.add(name)
                    changed = True
        reachable[owner] = owner_reachable
    return reachable


def is_reachable_view_position(
    document: SwiftSource,
    position: int,
    reachable: dict[str, set[str]],
) -> bool:
    owner = document.owner_at(position)
    scope = document.view_scope_at(position)
    return (
        owner is not None
        and scope is not None
        and scope.name in reachable.get(owner, set())
    )


def retry_action_bodies(
    document: SwiftSource,
    body_start: int,
    body_end: int,
) -> list[str]:
    bodies: list[str] = []
    source_body = document.source[body_start:body_end]
    for match in RETRY_LABEL.finditer(source_body):
        absolute_start = body_start + match.start()
        if not document.masked.startswith("Button", absolute_start):
            continue
        opening = document.source.rfind(
            "{",
            body_start + match.start(),
            body_start + match.end(),
        )
        closing = document.braces.get(opening)
        if closing is not None and closing <= body_end:
            bodies.append(document.masked[opening + 1:closing])
    return bodies


def retry_action_is_verified(
    owner: str,
    target: str,
    action: str,
    publishers: dict[tuple[str, str], set[str]],
) -> bool:
    for function in publishers.get((owner, target), set()):
        escaped_function = re.escape(function)
        direct_call = rf"\s*{escaped_function}\s*\(\s*\)\s*"
        task_call = (
            rf"\s*Task\s*\{{\s*(?:@MainActor\s+in\s*)?await\s+"
            rf"{escaped_function}\s*\(\s*\)\s*\}}\s*"
        )
        if re.fullmatch(direct_call, action) or re.fullmatch(task_call, action):
            return True
    history_generation_targets = {
        ("HistoryView", "initialPageErrorMessage"),
        ("HistoryView", "summaryErrorMessage"),
    }
    return (
        (owner, target) in history_generation_targets
        and re.fullmatch(r"\s*refreshGeneration\s*&\+=\s*1\s*", action) is not None
    )


def modifier_receiver_base_name(document: SwiftSource, position: int) -> str | None:
    """Return the base call in a standard chained Swift view expression."""
    inverse_parentheses = {
        closing: opening for opening, closing in document.parentheses.items()
    }
    inverse_braces = {closing: opening for opening, closing in document.braces.items()}
    cursor = position
    while cursor > 0:
        end = cursor - 1
        while end >= 0 and document.masked[end].isspace():
            end -= 1
        if end < 0:
            return None
        if document.masked[end] == "}":
            trailing_opening = inverse_braces.get(end)
            if trailing_opening is None:
                return None
            end = trailing_opening - 1
            while end >= 0 and document.masked[end].isspace():
                end -= 1
        if end < 0:
            return None
        if document.masked[end] == ")":
            opening = inverse_parentheses.get(end)
        else:
            opening = end + 1
        if opening is None:
            return None
        if opening == end + 1:
            name_end = end
        else:
            name_end = opening - 1
            while name_end >= 0 and document.masked[name_end].isspace():
                name_end -= 1
        name_start = name_end
        while name_start >= 0 and (
            document.masked[name_start].isalnum()
            or document.masked[name_start] == "_"
        ):
            name_start -= 1
        name = document.masked[name_start + 1:name_end + 1]
        preceding = name_start
        while preceding >= 0 and document.masked[preceding].isspace():
            preceding -= 1
        if preceding >= 0 and document.masked[preceding] == ".":
            cursor = preceding
            continue
        return name or None
    return None


def collect_valid_field_associations(
    documents: list[SwiftSource],
) -> dict[str, set[str]]:
    targets: dict[str, set[str]] = {}
    for document in documents:
        for match in FIELD_ASSOCIATION.finditer(document.masked):
            owner = document.owner_at(match.start())
            receiver = modifier_receiver_base_name(document, match.start())
            if owner is not None and receiver in INPUT_VIEW_NAMES:
                targets.setdefault(owner, set()).add(match.group("target"))
    return targets


def collect_operation_owners(
    documents: list[SwiftSource],
    reachable: dict[str, set[str]],
) -> dict[str, set[str]]:
    owners: dict[str, set[str]] = {}
    publishers = collect_safe_assignment_publishers(documents)
    for document in documents:
        for match in OPERATION_ALERT.finditer(document.masked):
            if is_reachable_view_position(document, match.start(), reachable) and (
                owner := document.owner_at(match.start())
            ):
                owners.setdefault(owner, set()).add(match.group("target"))

        for match in IF_LET.finditer(document.masked):
            opening = document.masked.rfind("{", match.start(), match.end())
            closing = document.braces.get(opening)
            owner = document.owner_at(match.start())
            if (
                closing is None
                or owner is None
                or not is_reachable_view_position(
                    document,
                    match.start(),
                    reachable,
                )
            ):
                continue
            body = document.masked[opening:closing]
            target = match.group("target")
            shows_target = bool(
                re.search(rf"\bText\s*\(\s*{re.escape(target)}\s*\)", body)
            )
            has_verified_retry = any(
                retry_action_is_verified(owner, target, action, publishers)
                for action in retry_action_bodies(document, opening, closing)
            )
            if shows_target and has_verified_retry:
                owners.setdefault(owner, set()).add(target)
    return owners


def collect_field_targets(
    documents: list[SwiftSource],
    pattern: re.Pattern[str],
) -> dict[str, set[str]]:
    targets: dict[str, set[str]] = {}
    for document in documents:
        for match in pattern.finditer(document.masked):
            if owner := document.owner_at(match.start()):
                targets.setdefault(owner, set()).add(match.group("target"))
    return targets


def validate_root_failure_route(documents: list[SwiftSource]) -> bool:
    root_sources = [
        document for document in documents if document.path.name == "RootView.swift"
    ]
    if len(root_sources) != 1:
        return False
    root = root_sources[0]
    dispatches = bool(
        re.search(
            r"case\s+let\s+\.failed\s*\(\s*message\s*\)\s*:"
            r"\s*RecoveryView\s*\(\s*message\s*:\s*message\s*\)",
            root.masked,
        )
    )
    recovery = next(
        (scope for scope in root.type_scopes if scope.name == "RecoveryView"),
        None,
    )
    if recovery is None:
        return False
    body = root.source[recovery.body_start:recovery.end]
    retry_actions = retry_action_bodies(root, recovery.body_start, recovery.end)
    retries_are_mapped = bool(retry_actions) and all(
        re.fullmatch(
            r"\s*Task\s*\{\s*(?:@MainActor\s+in\s*)?await\s+"
            r"model\s*\.\s*start\s*\(\s*\)\s*\}\s*",
            action,
        )
        for action in retry_actions
    )
    return (
        dispatches
        and re.search(r"\bText\s*\(\s*message\s*\)", body) is not None
        and retries_are_mapped
    )


def validate_failed_startup_route(documents: list[SwiftSource]) -> bool:
    for document in documents:
        if document.path.name != "AppModelLifecycle.swift":
            continue
        for scope in document.function_scopes:
            if scope.name != "finishFailedStartup":
                continue
            body = document.masked[scope.body_start:scope.end]
            if re.search(r"\bstate\s*=\s*\.failed\s*\(\s*message\s*\)", body):
                return True
    return False


def validate_history_unavailable_route(
    document: SwiftSource,
    function: str | None,
    operation_owners: dict[str, set[str]],
) -> bool:
    targets = {
        "initialPageOutcome": "initialPageErrorMessage",
        "summaryOutcome": "summaryErrorMessage",
    }
    target = targets.get(function or "")
    if target is None or target not in operation_owners.get("HistoryView", set()):
        return False
    mapping = re.compile(
        rf"case\s+let\s+\.unavailable\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\)"
        rf"\s*:\s*{re.escape(target)}\s*=",
    )
    return mapping.search(document.masked) is not None


def owned_function_body(
    document: SwiftSource,
    owner: str,
    function_name: str,
) -> str | None:
    matches = [
        scope for scope in document.function_scopes
        if scope.name == function_name
        and document.owner_at(scope.body_start + 1) == owner
    ]
    if len(matches) != 1:
        return None
    scope = matches[0]
    return document.masked[scope.body_start + 1:scope.end]


def validate_deferred_restore_failure_route(
    documents: list[SwiftSource],
    operation_owners: dict[str, set[str]],
) -> bool:
    """Verify the restore sheet dismisses before its native error alert."""

    candidates = [
        document
        for document in documents
        if document.path.name == "DataSafetyView.swift"
    ]
    if len(candidates) != 1:
        return False
    document = candidates[0]
    restore_body = owned_function_body(
        document,
        "DataSafetyView",
        "restoreBackup",
    )
    presenter_body = owned_function_body(
        document,
        "DataSafetyView",
        "presentRestoreResultAfterSheetDismissal",
    )
    reachable = reachable_view_scopes(documents).get("DataSafetyView", set())
    view_source = "\n".join(
        document.masked[scope.body_start + 1:scope.end]
        for scope in document.view_scopes
        if scope.name in reachable
        and document.owner_at(scope.body_start + 1) == "DataSafetyView"
    )
    return (
        restore_body is not None
        and presenter_body is not None
        and "errorMessage" in operation_owners.get("DataSafetyView", set())
        and re.search(
            r"restorePresentation\s*\.\s*queue\s*\(\s*\.failure\s*\(",
            restore_body,
        ) is not None
        and re.search(
            r"takeAfterSheetDismissal\s*\(\s*\)",
            presenter_body,
        ) is not None
        and re.search(
            r"case\s+let\s+\.failure\s*\(\s*failure\s*\)\s*:\s*"
            r"errorMessage\s*=\s*failure",
            presenter_body,
        ) is not None
        and re.search(
            r"onDismiss\s*:\s*presentRestoreResultAfterSheetDismissal",
            view_source,
        ) is not None
    )


def validate_safe_messages(
    documents: list[SwiftSource],
    operation_owners: dict[str, set[str]],
    field_associations: dict[str, set[str]],
    field_errors: dict[str, set[str]],
) -> list[str]:
    violations: list[str] = []
    root_route_is_accessible = validate_root_failure_route(documents)
    failed_startup_route_is_verified = validate_failed_startup_route(documents)
    deferred_restore_route_is_verified = validate_deferred_restore_failure_route(
        documents,
        operation_owners,
    )

    for document in documents:
        for match in SAFE_MESSAGE.finditer(document.masked):
            declaration_prefix = document.masked[max(0, match.start() - 24):match.start()]
            if re.search(r"\bfunc\s*$", declaration_prefix):
                continue
            owner = document.owner_at(match.start())
            opening = document.masked.find("(", match.start(), match.end())
            closing = document.parentheses.get(opening)
            if closing is None:
                violations.append(
                    f"{source_label(document, match.start())} has an unterminated "
                    "safeUserMessage call"
                )
                continue
            call = document.masked[match.start():closing + 1]
            context_match = re.search(r"\bcontext\s*:\s*\.([A-Za-z_][A-Za-z0-9_]*)", call)
            context = context_match.group(1) if context_match else "general"
            if owner is None:
                violations.append(
                    f"{source_label(document, match.start())} publishes a .{context} "
                    "safe message outside a declared owner scope"
                )
                continue

            prefix_start = max(0, match.start() - 180)
            prefix = document.masked[prefix_start:match.start()]
            target = direct_assignment_target(document, match.start())
            if target is not None:
                if target not in operation_owners.get(owner, set()):
                    violations.append(
                        f"{source_label(document, match.start())} publishes .{context} "
                        f"safe message {target} in {owner} without that owner's "
                        "accessible alert or target-bound retry summary"
                    )
                continue

            function = document.function_at(match.start())
            if function == "monetaryInputError":
                required_fields = {
                    "amountValidationMessage",
                    "destinationAmountValidationMessage",
                    "lineValidationMessage",
                }
                if (
                    owner == "QuickLogEntryView"
                    and required_fields <= field_associations.get(owner, set())
                    and required_fields <= field_errors.get(owner, set())
                ):
                    continue
                violations.append(
                    f"{source_label(document, match.start())} uses safeUserMessage "
                    "as field guidance without the verified Quick Log field route"
                )
                continue

            compact_prefix = re.sub(r"\s+", " ", prefix[-120:])
            is_failed_state = bool(
                owner == "AppModel"
                and re.search(
                    r"\bstate\s*=\s*\.failed\s*\(\s*$",
                    compact_prefix,
                )
            )
            is_failed_startup = bool(
                owner == "AppModel"
                and re.search(
                    r"finishFailedStartup\s*\(\s*message\s*:\s*$",
                    compact_prefix,
                )
            )
            if is_failed_state or is_failed_startup:
                route_is_verified = root_route_is_accessible and (
                    not is_failed_startup or failed_startup_route_is_verified
                )
                if not route_is_verified:
                    violations.append(
                        f"{source_label(document, match.start())} routes .{context} "
                        "failure state without the accessible RootView recovery summary"
                    )
                continue

            if re.search(r"\.unavailable\s*\(\s*$", compact_prefix):
                if not validate_history_unavailable_route(
                    document,
                    function,
                    operation_owners,
                ):
                    violations.append(
                        f"{source_label(document, match.start())} routes .{context} "
                        "unavailable output without a scoped retry summary"
                    )
                continue

            is_deferred_restore_failure = bool(
                owner == "DataSafetyView"
                and function == "restoreBackup"
                and re.search(
                    r"restorePresentation\s*\.\s*queue\s*\(\s*"
                    r"\.failure\s*\(\s*$",
                    compact_prefix,
                )
            )
            if (
                is_deferred_restore_failure
                and deferred_restore_route_is_verified
            ):
                continue

            violations.append(
                f"{source_label(document, match.start())} uses .{context} "
                "safeUserMessage through an unverified presentation route"
            )
    return violations


def validate_field_association(
    documents: list[SwiftSource],
    associations: dict[str, set[str]],
    field_errors: dict[str, set[str]],
) -> list[str]:
    violations: list[str] = []
    for document in documents:
        for match in FIELD_ASSOCIATION.finditer(document.masked):
            receiver = modifier_receiver_base_name(document, match.start())
            if receiver not in INPUT_VIEW_NAMES:
                violations.append(
                    f"{source_label(document, match.start())} attaches "
                    f"{match.group('target')} validation to {receiver or 'no view input'}; "
                    "attach it directly to TextField, SecureField, TextEditor, or DatePicker"
                )

    for owner in sorted(set(associations) | set(field_errors)):
        unlabelled = associations.get(owner, set()) - field_errors.get(owner, set())
        unassociated = field_errors.get(owner, set()) - associations.get(owner, set())
        for target in sorted(unlabelled):
            violations.append(
                f"{owner} associates {target} with an input but has no matching "
                "non-color-only MoneyUpFieldError"
            )
        for target in sorted(unassociated):
            violations.append(
                f"{owner} renders field error {target} without associating the same "
                "message with its input"
            )

    for document in documents:
        for match in RED_STYLE.finditer(document.masked):
            owner = document.owner_at(match.start())
            if owner == "MoneyUpFieldError":
                continue
            window = document.source[max(0, match.start() - 500):match.start()].lower()
            if any(marker in window for marker in ("invalid", "validation", "error")):
                violations.append(
                    f"{source_label(document, match.start())} passively renders "
                    "validation/error text in red; use target-associated MoneyUpFieldError"
                )
    return violations


def validate_documents(sources: dict[Path, str]) -> list[str]:
    documents = [
        SwiftSource.parse(path, source) for path, source in sorted(sources.items())
    ]
    reachable = reachable_view_scopes(documents)
    operation_owners = collect_operation_owners(documents, reachable)
    associations = collect_valid_field_associations(documents)
    field_errors = collect_field_targets(documents, FIELD_ERROR)
    return (
        validate_safe_messages(
            documents,
            operation_owners,
            associations,
            field_errors,
        )
        + validate_field_association(documents, associations, field_errors)
    )


def application_source_paths(project_source: str) -> list[str]:
    """Read the MoneyUp target's source roots from the checked-in project spec."""
    lines = project_source.splitlines()
    target_start = next(
        (
            index for index, line in enumerate(lines)
            if re.fullmatch(r"  MoneyUp\s*:\s*", line)
        ),
        None,
    )
    if target_start is None:
        raise ValueError("project.yml has no MoneyUp application target")
    target_end = next(
        (
            index for index in range(target_start + 1, len(lines))
            if re.match(r"^  [^\s].*:\s*$", lines[index])
        ),
        len(lines),
    )
    source_start = next(
        (
            index for index in range(target_start + 1, target_end)
            if re.fullmatch(r"    sources\s*:\s*", lines[index])
        ),
        None,
    )
    if source_start is None:
        raise ValueError("MoneyUp target has no sources list")

    paths: list[str] = []
    for line in lines[source_start + 1:target_end]:
        if line.strip() and len(line) - len(line.lstrip()) <= 4:
            break
        match = re.match(
            r"^\s{6}-\s+(?:path\s*:\s*)?(?P<path>[^#]+?)\s*$",
            line,
        )
        if match:
            paths.append(match.group("path").strip().strip("'\""))
    if not paths:
        raise ValueError("MoneyUp target sources list is empty")
    return paths


def discover_swift_sources(source_roots: list[Path]) -> list[Path]:
    discovered: set[Path] = set()
    for source_root in source_roots:
        if source_root.is_file() and source_root.suffix == ".swift":
            discovered.add(source_root.resolve())
        elif source_root.is_dir():
            discovered.update(path.resolve() for path in source_root.rglob("*.swift"))
    return sorted(discovered)


def configured_application_swift_sources() -> list[Path]:
    relative_paths = application_source_paths(PROJECT_FILE.read_text(encoding="utf-8"))
    roots: list[Path] = []
    for relative_path in relative_paths:
        candidate = (ROOT / relative_path).resolve()
        try:
            candidate.relative_to(ROOT.resolve())
        except ValueError as error:
            raise ValueError(
                f"MoneyUp source root escapes the repository: {relative_path}"
            ) from error
        if not candidate.exists():
            raise ValueError(f"MoneyUp source root does not exist: {relative_path}")
        roots.append(candidate)
    sources = discover_swift_sources(roots)
    if not sources:
        raise ValueError("MoneyUp target has no discoverable Swift sources")
    return sources


def self_test() -> list[str]:
    failures: list[str] = []
    fixture = APP_ROOT / "Fixture.swift"

    accepted_operation = """
    struct Editor {
        @State var errorMessage: String?
        func save() {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }
    extension Editor: View {
        var body: some View {
            Text("form").moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if validate_documents({fixture: accepted_operation}):
        failures.append("scoped operation alert fixture was rejected")

    dead_same_owner_alert = """
    struct BrokenEditor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
        var body: some View { Text("form") }
        func unreachableAlert() {
            Text("dead").moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if not validate_documents({fixture: dead_same_owner_alert}):
        failures.append("dead same-owner alert incorrectly satisfied ownership")

    unreachable_computed_alert = """
    struct BrokenEditor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
        var body: some View { Text("form") }
        var unusedErrorView: some View {
            Text("dead").moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if not validate_documents({fixture: unreachable_computed_alert}):
        failures.append("unreachable computed alert incorrectly satisfied ownership")

    reachable_computed_alert = """
    struct Editor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
        var body: some View { form }
        var form: some View {
            Text("form").moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if validate_documents({fixture: reachable_computed_alert}):
        failures.append("reachable computed alert fixture was rejected")

    cross_scope_operation = """
    struct BrokenEditor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .scan)
        }
    }
    struct UnrelatedView: View {
        var body: some View {
            Text("other").moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if not validate_documents({fixture: cross_scope_operation}):
        failures.append("cross-struct operation alert incorrectly satisfied ownership")

    unrelated_native_alert = """
    struct BrokenEditor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .unlock)
        }
        var body: some View {
            Text("form").alert("Other", isPresented: $showsOther) {}
        }
    }
    """
    if not validate_documents({fixture: unrelated_native_alert}):
        failures.append("unrelated native alert incorrectly satisfied ownership")

    wrong_target_alert = """
    struct BrokenEditor: View {
        func save() {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
        var body: some View {
            Text("form").moneyUpOperationErrorAlert(message: $differentError)
        }
    }
    """
    if not validate_documents({fixture: wrong_target_alert}):
        failures.append("wrong alert binding incorrectly satisfied target ownership")

    accepted_retry = """
    struct RetryView: View {
        func load() {
            errorMessage = safeUserMessage(for: error, context: .read)
        }
        var body: some View {
            if let errorMessage {
                Text(errorMessage)
                Button("action.retry") { load() }
            }
        }
    }
    """
    if validate_documents({fixture: accepted_retry}):
        failures.append("target-bound retry summary fixture was rejected")

    unrelated_retry = """
    struct BrokenRetryView: View {
        func load() {
            errorMessage = safeUserMessage(for: error, context: .read)
        }
        var body: some View {
            if let errorMessage { Text(errorMessage) }
            Button("action.retry") { load() }
        }
    }
    """
    if not validate_documents({fixture: unrelated_retry}):
        failures.append("unrelated retry button incorrectly satisfied ownership")

    noop_retry = """
    struct BrokenRetryView: View {
        func load() {
            errorMessage = safeUserMessage(for: error, context: .read)
        }
        var body: some View {
            if let errorMessage {
                Text(errorMessage)
                Button("action.retry") {}
            }
        }
    }
    """
    if not validate_documents({fixture: noop_retry}):
        failures.append("no-op retry button incorrectly satisfied retry mapping")

    disguised_field_route = """
    struct BrokenEditor: View {
        func monetaryInputError() -> String {
            safeUserMessage(for: error, context: .save)
        }
    }
    """
    if not validate_documents({fixture: disguised_field_route}):
        failures.append("function-name-only field route bypassed scoped validation")

    for context, call in (
        ("general", "safeUserMessage(for: error)"),
        ("scan", "safeUserMessage(for: error, context: .scan)"),
        ("unlock", "safeUserMessage(for: error, context: .unlock)"),
    ):
        missing_route = f"""
        struct MissingRoute {{
            func run() {{ errorMessage = {call} }}
        }}
        """
        if not validate_documents({fixture: missing_route}):
            failures.append(f".{context} safe message escaped presentation validation")

    accepted_field = """
    struct AmountEditor: View {
        var body: some View {
            TextField("Amount", text: $amount)
                .moneyUpFieldValidation(amountValidationMessage)
            MoneyUpFieldError(message: amountValidationMessage)
        }
    }
    """
    if validate_documents({fixture: accepted_field}):
        failures.append("associated field validation fixture was rejected")

    missing_field_association = """
    struct AmountEditor: View {
        var body: some View {
            TextField("Amount", text: $amount)
            MoneyUpFieldError(message: amountValidationMessage)
        }
    }
    """
    if not validate_documents({fixture: missing_field_association}):
        failures.append("field error without input association was accepted")

    cross_scope_field = """
    struct AmountEditor: View {
        var body: some View { MoneyUpFieldError(message: validationMessage) }
    }
    struct OtherEditor: View {
        var body: some View {
            TextField("Other", text: $other)
                .moneyUpFieldValidation(validationMessage)
        }
    }
    """
    if not validate_documents({fixture: cross_scope_field}):
        failures.append("cross-struct field hint incorrectly satisfied association")

    non_input_field = """
    struct AmountEditor: View {
        var body: some View {
            Text("Not an input")
                .moneyUpFieldValidation(amountValidationMessage)
            MoneyUpFieldError(message: amountValidationMessage)
        }
    }
    """
    if not validate_documents({fixture: non_input_field}):
        failures.append("non-input view incorrectly satisfied field association")

    nested_owner_collision = """
    struct FirstContainer {
        struct Editor {
            func save() {
                errorMessage = safeUserMessage(for: error, context: .save)
            }
        }
    }
    struct SecondContainer {
        struct Editor: View {
            var body: some View {
                Text("other").moneyUpOperationErrorAlert(message: $errorMessage)
            }
        }
    }
    """
    if not validate_documents({fixture: nested_owner_collision}):
        failures.append("same-named nested owners incorrectly satisfied each other")

    root_fixture = APP_ROOT / "RootView.swift"
    lifecycle_fixture = APP_ROOT / "AppModelLifecycle.swift"
    unrelated_fixture = APP_ROOT / "Unrelated.swift"
    root_route = """
    struct RootView: View {
        var body: some View {
            switch state {
            case let .failed(message): RecoveryView(message: message)
            }
        }
    }
    struct RecoveryView: View {
        let message: String
        var body: some View {
            Text(message)
            Button("action.try_again") { Task { await model.start() } }
        }
    }
    """
    failed_startup_route = """
    extension AppModel {
        func finishFailedStartup() { state = .failed(message) }
    }
    """
    unrelated_failed_state = """
    struct Unrelated {
        func run() {
            localState = .failed(safeUserMessage(for: error, context: .read))
        }
    }
    """
    if not validate_documents(
        {
            root_fixture: root_route,
            lifecycle_fixture: failed_startup_route,
            unrelated_fixture: unrelated_failed_state,
        }
    ):
        failures.append("unrelated .failed value escaped through AppModel recovery exception")

    app_model_failed_state = """
    extension AppModel {
        func fail() {
            state = .failed(safeUserMessage(for: error, context: .save))
        }
    }
    """
    if validate_documents(
        {
            root_fixture: root_route,
            lifecycle_fixture: app_model_failed_state,
        }
    ):
        failures.append("AppModel.state recovery route fixture was rejected")

    noop_root_route = root_route.replace(
        'Button("action.try_again") { Task { await model.start() } }',
        'Button("action.try_again") {}',
    )
    if not validate_documents(
        {
            root_fixture: noop_root_route,
            lifecycle_fixture: app_model_failed_state,
        }
    ):
        failures.append("no-op root retry incorrectly satisfied recovery routing")

    dynamic_root_route = root_route.replace(
        'Button("action.try_again")',
        "Button(retryActionKey)",
    )
    if not validate_documents(
        {
            root_fixture: dynamic_root_route,
            lifecycle_fixture: app_model_failed_state,
        }
    ):
        failures.append("dynamic root retry label bypassed the immutable action pin")

    mixed_root_route = root_route.replace(
        'Button("action.try_again") { Task { await model.start() } }',
        'Button("action.try_again") { Task { await model.start() } }\n'
        'Button("recovery.key_cliff.retry") {}',
    )
    if not validate_documents(
        {
            root_fixture: mixed_root_route,
            lifecycle_fixture: app_model_failed_state,
        }
    ):
        failures.append("one mapped root retry concealed a second no-op retry")

    passive_operation = """
    struct RestoreView: View {
        func restore() {
            errorMessage = safeUserMessage(for: error, context: .restoreData)
        }
        var body: some View {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
    }
    """
    if len(validate_documents({fixture: passive_operation})) < 2:
        failures.append("passive operation error was not rejected by both gates")

    data_safety_fixture = APP_ROOT / "DataSafetyView.swift"
    deferred_restore = """
    struct DataSafetyView: View {
        func restoreBackup() {
            restorePresentation.queue(
                .failure(safeUserMessage(for: error, context: .restoreData))
            )
        }
        func presentRestoreResultAfterSheetDismissal() {
            guard let result = restorePresentation.takeAfterSheetDismissal()
                else { return }
            switch result {
            case let .failure(failure): errorMessage = failure
            case .success: break
            }
        }
        var body: some View {
            Text("form")
                .sheet(
                    isPresented: $shown,
                    onDismiss: presentRestoreResultAfterSheetDismissal
                ) { Text("preview") }
                .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }
    """
    if validate_documents({data_safety_fixture: deferred_restore}):
        failures.append("same-function deferred restore route was rejected")

    split_deferred_restore = deferred_restore.replace(
        "case let .failure(failure): errorMessage = failure",
        "case .failure: unrelated()",
    ).replace(
        "var body: some View {",
        "func unrelated() { errorMessage = failure }\n"
        "        var body: some View {",
    )
    if not validate_documents({data_safety_fixture: split_deferred_restore}):
        failures.append(
            "cross-function deferred restore assignment incorrectly satisfied routing"
        )

    project_fixture = """targets:
  MoneyUp:
    type: application
    sources:
      - path: App/MoneyUp
      - path: App/Shared
    dependencies: []
  MoneyUpTests:
    type: bundle.unit-test
"""
    if application_source_paths(project_fixture) != ["App/MoneyUp", "App/Shared"]:
        failures.append("project source-root inventory parser missed application roots")
    with tempfile.TemporaryDirectory() as temporary_directory:
        source_root = Path(temporary_directory) / "App"
        nested_root = source_root / "Feature"
        nested_root.mkdir(parents=True)
        nested_source = nested_root / "Nested.swift"
        nested_source.write_text("struct Nested {}\n", encoding="utf-8")
        if discover_swift_sources([source_root]) != [nested_source.resolve()]:
            failures.append("recursive source discovery missed nested Swift source")

    return failures


def main() -> int:
    try:
        source_paths = configured_application_swift_sources()
    except (OSError, ValueError) as error:
        print(f"error: could not inventory MoneyUp Swift sources: {error}", file=sys.stderr)
        return 1
    sources = {path: path.read_text(encoding="utf-8") for path in source_paths}
    violations = self_test() + validate_documents(sources)
    if violations:
        for violation in violations:
            print(f"error: {violation}", file=sys.stderr)
        return 1
    print(
        "Validated accessible errors: every safe operation route has scoped "
        "ownership and every field message is associated with its input"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
