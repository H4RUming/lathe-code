#!/usr/bin/env python3
"""Validate native UI localization keys and format arguments without a model service."""

import json
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Packages/LatheKit/Sources/LatheLocalization/Resources"
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|[hlqztj])?([@diuoxXfFeEgGaAcCsSp%])")
LOOKUP = re.compile(r'L10n\.(text|format)\(\s*"([^"\\]+)"(?:\s*,\s*table:\s*"([^"\\]+)")?')
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
    sources = {path: path.read_text() for path in (ROOT / "Apps/Lathe/Sources").glob("*.swift")}
    format_sources = list(sources.values())
    helper_tests = ROOT / "Packages/LatheKit/Tests/LatheKitTests/LocalizationTests.swift"
    if helper_tests.exists():
        format_sources.append(helper_tests.read_text())
    formatted_keys = {(table or "Interface", key) for source in format_sources
                      for method, key, table in LOOKUP.findall(source) if method == "format"}
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
        lookups = [(key, table) for _, key, table in LOOKUP.findall(source)]
        lookups.extend((key, "AppMessages") for key in DISCONNECT_LOOKUP.findall(source))
        for key, name in lookups:
            name = name or "Interface"
            if key not in tables["ko"].get(name, {}):
                errors.append(f"{path.name}: missing localization {name}/{key}")
        for match in list(DISPLAY_LITERAL.finditer(source)) + list(APPKIT_LITERAL.finditer(source)):
            if match.group(1) not in {"", "Lathe"}:
                line = source.count("\n", 0, match.start()) + 1
                errors.append(f"{path.name}:{line}: hardcoded UI text; use a localization key")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    count = sum(len(table) for table in tables["ko"].values())
    print(f"PASS localization: {count} keys, matching Korean/English tables and format arguments, native UI lookups")
    return 0


if __name__ == "__main__":
    sys.exit(main())
