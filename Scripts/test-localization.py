#!/usr/bin/env python3
"""Regression checks for the localization guard, including core error messages."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("localization", Path(__file__).with_name("check-localization.py"))
localization = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localization)


class LocalizationGuardTests(unittest.TestCase):
    def check(self, source, tables=None):
        return localization.source_errors("Fixture.swift", source, tables or {})

    def test_rejects_korean_and_english_core_errors(self):
        for text in ["연결할 수 없습니다.", "Unable to connect."]:
            with self.subTest(text=text):
                self.assertTrue(self.check(f'throw LatheError.transport("{text}")'))
                self.assertTrue(self.check(f'var errorDescription: String? {{ "{text}" }}'))
                self.assertTrue(self.check(f'var errorDescription: String? {{ switch self {{ case .failed: "{text}" }} }}'))

    def test_checks_nested_lookup_keys_in_error_descriptions(self):
        source = 'var errorDescription: String? { L10n.errorFormat("error.failed", table: "Errors", detail) }'
        self.assertTrue(self.check(source))
        self.assertFalse(self.check(source, {"Errors": {"error.failed": "Failed: %@"}}))

    def test_errors_must_use_the_error_language_channel(self):
        tables = {"ProviderErrors": {"provider.failed": "Failed"}}
        self.assertTrue(self.check('L10n.text("provider.failed", table: "ProviderErrors")', tables))
        self.assertFalse(self.check('L10n.errorText("provider.failed", table: "ProviderErrors")', tables))
        self.assertTrue(self.check('var errorDescription: String? { L10n.text("failed") }', {"Interface": {"failed": "Failed"}}))

    def test_detects_ui_status_and_error_sinks(self):
        for source in ['Text("Hello")', 'alert.messageText = "Failed"',
                       'ToolResult(output: "Denied")', 'RPCFailure(message: "Invalid request")',
                       'summary = "Read file"', 'item.output = "Execution denied"']:
            with self.subTest(source=source):
                self.assertTrue(self.check(source))

    def test_leaves_comments_machine_values_and_raw_diagnostics_alone(self):
        source = '''
        // 한국어 설명과 예시: throw LatheError.storage("실패")
        /* Text("Display") */
        let endpoint = "https://example.invalid/v1"
        throw SocketTransportError.systemCall("posix_spawn", code)
        var errorDescription: String? { message }
        '''
        self.assertFalse(self.check(source))

    def test_plain_percent_is_valid_text_but_formats_require_escaping(self):
        self.assertFalse(self.check('Text(L10n.text("progress"))', {"Interface": {"progress": "100% ready"}}))
        self.assertEqual(localization.arguments("%2$@ has %1$lld items (100%%)"), {2: "@", 1: "lld"})
        with self.assertRaises(ValueError):
            localization.arguments("100% ready")


if __name__ == "__main__":
    unittest.main()
