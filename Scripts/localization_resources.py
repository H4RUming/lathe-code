"""Read actual translations for locale-independent integration assertions."""

from functools import lru_cache
import json
from pathlib import Path
import subprocess

RESOURCES = Path(__file__).resolve().parents[1] / "Packages/LatheKit/Sources/LatheLocalization/Resources"


@lru_cache
def table(language, name):
    path = RESOURCES / f"{language}.lproj" / f"{name}.strings"
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def translations(name, key):
    return {table(language, name)[key] for language in ("ko", "en")}
