#!/usr/bin/env python3
"""Validate checked-in Simplified Chinese strings, optionally against compiler extraction."""
import argparse
import json
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PREVIEW_KEYS = {
    "Dark frosted glass background", "EQ Card - Lifted", "EQ Panel Content",
    "Expanded Content", "Expanded detail content here", "MacBook Pro Speakers",
    "Sample content goes here", "Secondary information", "Test Component",
}
FORMAT = re.compile(r"%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?)?(?:ll|l|h)?[@diuofsg]")


def placeholders(text):
    return sorted(re.sub(r"^%\d+\$", "%", token) for token in FORMAT.findall(text.replace("%%", "")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stringsdata-root", type=pathlib.Path)
    args = parser.parse_args()
    errors = []
    catalog = json.loads((ROOT / "FineTune/Resources/Localizable.xcstrings").read_text())
    keys = set(catalog["strings"])
    for table in ("Localizable", "InfoPlist"):
        resource = json.loads((ROOT / f"FineTune/Resources/{table}.xcstrings").read_text())
        for key, entry in resource["strings"].items():
            unit = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                errors.append(f"{table}: missing Chinese translation: {key}")
            if table == "Localizable" and placeholders(key) != placeholders(unit.get("value", "")):
                errors.append(f"{table}: format placeholders differ: {key}")
    # String-valued shared components do not appear in compiler extraction.
    for source in (ROOT / "FineTune/Views").rglob("*.swift"):
        text = source.read_text().split("#Preview", 1)[0]
        for match in re.finditer(r'(?:SettingsRow|SettingsSection|SectionHeader)\s*\(\s*(?:title:\s*)?"([^"\\]+)"', text):
            if match[1] not in keys:
                errors.append(f"{source.relative_to(ROOT)}: untranslated shared title: {match[1]}")
    if args.stringsdata_root:
        files = list(args.stringsdata_root.rglob("*.stringsdata"))
        if not files:
            errors.append("No compiler .stringsdata files found; build FineTune first.")
        for source in files:
            try:
                data = json.loads(source.read_bytes())
            except (ValueError, UnicodeError):
                data = plistlib.loads(source.read_bytes())
            for entry in data.get("tables", {}).get("Localizable", []):
                key = entry["key"]
                if key and key not in keys and key not in PREVIEW_KEYS:
                    errors.append(f"{pathlib.Path(data['source']).name}: untranslated extracted key: {key}")
    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        return 1
    print(f"Chinese localization passed: {len(keys)} UI keys and InfoPlist permission strings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
