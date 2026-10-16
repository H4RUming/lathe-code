#!/usr/bin/env python3
"""Verify translated diagnostics in relocated app helpers and optional developer tools."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from localization_resources import RESOURCES, table


def render(pattern, value):
    # These diagnostic wrappers each take exactly one string argument. Do not
    # interpret percent signs that belong to the raw argument itself.
    return re.sub(r"%(?:1\$)?@", lambda _: value, pattern)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    args = parser.parse_args()
    source = args.bin_dir.resolve()
    with tempfile.TemporaryDirectory(prefix="lathe-localization-") as temporary:
        root = Path(temporary)
        app = root / "Lathe.app"
        shutil.copytree(source / "Lathe.app", app)
        resources = app / "Contents/Resources/LatheKit_LatheLocalization.bundle"
        resource_files = resources / "Contents/Resources"
        if not resource_files.is_dir():
            resource_files = resources
        for language in ("ko", "en"):
            for path in (RESOURCES / f"{language}.lproj").glob("*.strings"):
                assert (resource_files / f"{language}.lproj" / path.name).is_file(), path.name

        # Copy optional tools beside their own bundle to cover both supported layouts.
        developer = root / "developer"
        developer.mkdir()
        for name in ("lathe", "lathe-engine", "lathe-runner"):
            shutil.copy2(source / name, developer / name)
        shutil.copytree(source / "LatheKit_LatheLocalization.bundle", developer / "LatheKit_LatheLocalization.bundle")

        def invoke(executable, words, language, expected, error_language=None):
            environment = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "LATHE_DISPLAY_LANGUAGE": language}
            if error_language:
                environment["LATHE_ERROR_LANGUAGE"] = error_language
            result = subprocess.run([str(executable), *words], cwd=root,
                                    env=environment,
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode == expected, (executable, language, result.returncode, result.stderr)
            return result

        for language in ("ko", "en"):
            runner_messages = table(language, "RunnerMessages")
            cli_messages = table(language, "CLIMessages")
            for runner in (app / "Contents/Helpers/lathe-runner", developer / "lathe-runner"):
                assert invoke(runner, ["--help"], language, 0).stdout == runner_messages["runner.help"] + "\n"
                assert invoke(runner, [], language, 1).stderr == render(runner_messages["runner.error"], runner_messages["runner.usage"])
            assert invoke(developer / "lathe", ["--help"], language, 0).stdout == cli_messages["cli.help"] + "\n"
            option = "--fixture-100%-%@-raw"
            expected = render(cli_messages["cli.error"], render(cli_messages["cli.unknownOption"], option)) + "\n"
            assert invoke(developer / "lathe", [option], language, 1).stderr == expected
            expected = render(cli_messages["engine.error"], cli_messages["engine.usage"])
            assert invoke(developer / "lathe-engine", [], language, 1).stderr == expected
            print(f"PASS {language}: relocated app helper, developer tools, translated errors, raw argument preservation", flush=True)
            error_language = "en" if language == "ko" else "ko"
            runner_errors, cli_errors = table(error_language, "RunnerMessages"), table(error_language, "CLIMessages")
            for runner in (app / "Contents/Helpers/lathe-runner", developer / "lathe-runner"):
                assert invoke(runner, ["--help"], language, 0, error_language).stdout == runner_messages["runner.help"] + "\n"
                expected = render(runner_errors["runner.error"], runner_errors["runner.usage"])
                assert invoke(runner, [], language, 1, error_language).stderr == expected
            assert invoke(developer / "lathe", ["--help"], language, 0, error_language).stdout == cli_messages["cli.help"] + "\n"
            expected = render(cli_errors["cli.error"], render(cli_errors["cli.unknownOption"], option)) + "\n"
            assert invoke(developer / "lathe", [option], language, 1, error_language).stderr == expected
            expected = render(cli_errors["engine.error"], cli_errors["engine.usage"])
            assert invoke(developer / "lathe-engine", [], language, 1, error_language).stderr == expected
            print(f"PASS interface={language}, errors={error_language}: independent helper/CLI language channels", flush=True)


if __name__ == "__main__":
    main()
