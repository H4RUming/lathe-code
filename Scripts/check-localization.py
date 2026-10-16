#!/usr/bin/env python3
"""Validate app/core localization resources and common user-facing string sinks."""

import json
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Packages/LatheKit/Sources/LatheLocalization/Resources"
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|[hlqztj])?([@diuoxXfFeEgGaAcCsSp%])")
LOOKUP = re.compile(r'L10n\.(text|format|errorText|errorFormat)\(\s*"([^"\\]+)"(?:\s*,\s*table:\s*"([^"\\]+)")?')
ERROR_TABLES = {"DomainErrors", "ProviderErrors", "ProtocolErrors", "HostErrors", "StorageErrors", "ExecutionErrors"}
DISCONNECT_LOOKUP = re.compile(r'disconnectAfterFailure\(\s*"([^"\\]+)"')
DISPLAY_LITERAL = re.compile(
    r'\b(?:Text|Button|Label|Section|LabeledContent|Picker|TextField|SecureField|Toggle|'
    r'WindowGroup|CommandMenu|ContentUnavailableView|DisclosureGroup|ProgressView|help|accessibilityLabel|navigationTitle)'
    r'\(\s*"((?:\\.|[^"\\])*)"'
)
APPKIT_LITERAL = re.compile(
    r'(?:\b(?:messageText|informativeText|toolTip|prompt|message)\s*=\s*|'
    r'\b(?:addButton\(withTitle:|NSMenuItem\(title:)\s*)"((?:\\.|[^"\\])*)"'
)
# System-call operation identifiers (e.g. posix_spawn, bind) are diagnostic data.
# All other fixed error messages, including English ones, belong in resources.
ERROR_LITERAL = re.compile(
    r'\b(?:(?:LatheError|ProviderError|SocketTransportError|ToolError|CommandExecutionError|RunnerFailure)'
    r'\.(?!(?:systemCall|io)\b)\w+|storageError|UsageError)\(\s*"((?:\\.|[^"\\])*)"'
)
RESULT_LITERAL = re.compile(r'\b(?:(?:summary|output|error|message):|(?:summary|output)\s*=)\s*"((?:\\.|[^"\\])*)"')
ERROR_DESCRIPTION = re.compile(r'\bvar\s+errorDescription\s*:\s*String\?\s*\{')
# Retain literal text, but mask comments so prose in comments cannot cause a failure.
SWIFT_TOKEN = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')


def without_comments(source):
    return SWIFT_TOKEN.sub(lambda m: re.sub(r'[^\n]', ' ', m.group())
                           if m.group().startswith(('//', '/*')) else m.group(), source)


def error_description_ranges(source):
    # Hide literal braces before finding the matching end of each computed property.
    masked = SWIFT_TOKEN.sub(lambda m: re.sub(r'[^\n]', ' ', m.group()), source)
    for match in ERROR_DESCRIPTION.finditer(source):
        depth = 1
        for end in range(match.end(), len(masked)):
            depth += (masked[end] == '{') - (masked[end] == '}')
            if depth == 0:
                yield match.end(), end
                break


def source_errors(path, original, tables):
    source = without_comments(original)
    errors = []
    lookups = [(key, table) for _, key, table in LOOKUP.findall(source)]
    lookups.extend((key, "AppMessages") for key in DISCONNECT_LOOKUP.findall(source))
    for key, name in lookups:
        name = name or "Interface"
        if key not in tables.get(name, {}):
            errors.append(f"{path}: missing localization {name}/{key}")
    for method, key, name in LOOKUP.findall(source):
        if (name in ERROR_TABLES or key.startswith("app.error.")) and not method.startswith("error"):
            errors.append(f"{path}: error lookup {key} must use errorText/errorFormat")
    matches = []
    for pattern in (DISPLAY_LITERAL, APPKIT_LITERAL, ERROR_LITERAL, RESULT_LITERAL):
        matches.extend((m.start(), m.group(1)) for m in pattern.finditer(source))
    for start, end in error_description_ranges(source):
        if any(not method.startswith("error") for method, _, _ in LOOKUP.findall(source[start:end])):
            errors.append(f"{path}: errorDescription must use the error language channel")
        # Lookup keys and table names are not display text.
        body = LOOKUP.sub(lambda m: ' ' * len(m.group()), source[start:end])
        matches.extend((start + m.start(), m.group()) for m in SWIFT_TOKEN.finditer(body))
    # Korean literals elsewhere in production Swift are also a useful regression
    # signal, even when a new error/helper API isn't known to the sink patterns.
    for match in SWIFT_TOKEN.finditer(source):
        if re.search(r'[가-힣]', match.group()):
            matches.append((match.start(), match.group()))
    for offset, value in sorted(set(matches)):
        if value not in {"", "Lathe"}:
            line = source.count("\n", 0, offset) + 1
            errors.append(f"{path}:{line}: hardcoded display/error text; use a localization key")
    return errors


def load_table(path):
    keys = re.findall(r'^\s*"((?:\\.|[^"\\])*)"\s*=', path.read_text(), re.MULTILINE)
    duplicates = [key for key, count in Counter(keys).items() if count > 1]
    if duplicates:
        raise ValueError(f"Duplicate keys in {path}: {duplicates}")
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                            capture_output=True, text=True, check=True)
    table = json.loads(result.stdout)
    if not isinstance(table, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in table.items()):
        raise ValueError(f"Invalid string table: {path}")
    return table


def arguments(value):
    result = {}
    implicit_index = 1
    end = 0
    for match in PLACEHOLDER.finditer(value):
        if "%" in value[end:match.start()]:
            raise ValueError(f"Unsupported format placeholder: {value}")
        end = match.end()
        position, length, kind = match.groups()
        if kind == "%":
            continue
        index = int(position) if position else implicit_index
        if not position:
            implicit_index += 1
        argument_type = (length or "") + kind
        if index in result and result[index] != argument_type:
            raise ValueError(f"Conflicting format argument {index}: {value}")
        result[index] = argument_type
    if "%" in value[end:]:
        raise ValueError(f"Unescaped percent sign: {value}")
    return result


def main():
    errors = []
    tables = {}
    sources = {path: path.read_text() for directory in (ROOT / "Apps/Lathe/Sources", ROOT / "Packages/LatheKit/Sources")
               for path in directory.rglob("*.swift")}
    format_sources = list(sources.values())
    helper_tests = ROOT / "Packages/LatheKit/Tests/LatheKitTests/LocalizationTests.swift"
    if helper_tests.exists():
        format_sources.append(helper_tests.read_text())
    formatted_keys = {(table or "Interface", key) for source in format_sources
                      for method, key, table in LOOKUP.findall(source) if method.lower().endswith("format")}
    formatted_keys.update(("AppMessages", key) for source in sources.values()
                          for key in DISCONNECT_LOOKUP.findall(source))
    for language in ("ko", "en"):
        tables[language] = {path.stem: load_table(path) for path in (RESOURCES / f"{language}.lproj").glob("*.strings")}
        if not tables[language]:
            errors.append(f"No {language} localization tables found")
    if tables["ko"].keys() != tables["en"].keys():
        errors.append("Korean and English table names differ")
    for name in tables["ko"].keys() & tables["en"].keys():
        korean, english = tables["ko"][name], tables["en"][name]
        if korean.keys() != english.keys():
            errors.append(f"{name}: missing translation keys {sorted(korean.keys() ^ english.keys())}")
        for key in korean.keys() & english.keys():
            if (name, key) in formatted_keys and arguments(korean[key]) != arguments(english[key]):
                errors.append(f"{name}/{key}: format argument types differ")
    for path, source in sources.items():
        errors.extend(source_errors(path.relative_to(ROOT), source, tables["ko"]))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    count = sum(len(table) for table in tables["ko"].values())
    print(f"PASS localization: {count} keys, matching Korean/English tables and format arguments, app/core lookups and error text")
    return 0


if __name__ == "__main__":
    sys.exit(main())
