#!/usr/bin/env python3
"""Regenerate Sources/dsh/AgentProfileYAML.swift from Resources/AgentProfiles/*.patch.yml.

The .patch.yml files are the source of truth: they are vendored verbatim from
upstream and copied into the app bundle, where AgentProfiles.yamlSource() reads
them first. AgentProfileYAML.swift is an embedded fallback for development
binaries that have no resource bundle, so it must stay byte-identical to the
files it mirrors.

Usage:
    python3 scripts/vendor-agent-profiles.py           # rewrite the Swift file
    python3 scripts/vendor-agent-profiles.py --check   # exit 1 if out of date

Re-vendoring from upstream is a separate step: copy the four files out of
packages/bundle/web-app/presets/ into Resources/AgentProfiles/, update the
commit hash in the header below, then run this script.
"""

import argparse
import pathlib
import sys

COMMIT = "fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159"
COMMIT_DATE = "2026-11-04"
NAMES = ["standard", "minimal", "ptc", "cordis"]

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources" / "AgentProfiles"
OUT = ROOT / "Sources" / "dsh" / "AgentProfileYAML.swift"

HEADER = f'''import Foundation

// GENERATED — do not edit by hand. Regenerate with:
//   python3 scripts/vendor-agent-profiles.py
//
// Vendored verbatim from the official DeepSeek Harness repository
// (https://github.com/deepseek-ai/deepseek-harness).
// Third-party material: Copyright (c) 2026 DeepSeek, MIT License.
// See THIRD_PARTY_NOTICES.md for the full license text.
//   commit: {COMMIT} (master, {COMMIT_DATE})
//   source: packages/bundle/web-app/presets/{{standard,minimal,ptc,cordis}}.patch.yml
// Embedded fallback copies of Resources/AgentProfiles/*.patch.yml — the
// bundle resources are the source of truth and are read first at runtime
// (see AgentProfiles.yamlSource). Keep these byte-identical to the files in
// Resources/AgentProfiles/ when refreshing the vendored presets.

enum AgentProfileYAML {{
'''


def swift_literal(yaml: str) -> str:
    """Escape a YAML document for a Swift multi-line string literal.

    Swift multi-line literals end at a line containing only the closing
    delimiter, so a YAML line that is exactly `\"\"\"` would terminate early.
    Escape backslashes and any `\"\"\"` sequence; the result decodes back to the
    original bytes.
    """
    out = yaml.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    if not out.endswith("\n"):
        out += "\n"
    return out


def render() -> str:
    parts = [HEADER]
    for name in NAMES:
        src = (RESOURCES / f"{name}.patch.yml").read_text(encoding="utf-8")
        parts.append(f'    static let {name}: String = """\n')
        parts.append(swift_literal(src))
        parts.append('"""\n\n')
    parts.append("}\n")
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify the generated file is current instead of writing it")
    args = ap.parse_args()

    missing = [n for n in NAMES if not (RESOURCES / f"{n}.patch.yml").exists()]
    if missing:
        print(f"missing vendored presets: {', '.join(missing)}", file=sys.stderr)
        return 2

    want = render()
    have = OUT.read_text(encoding="utf-8") if OUT.exists() else ""

    if args.check:
        if want != have:
            print(f"{OUT.relative_to(ROOT)} is out of date; run "
                  f"python3 scripts/vendor-agent-profiles.py", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} is current")
        return 0

    if want == have:
        print(f"{OUT.relative_to(ROOT)} already current")
        return 0
    OUT.write_text(want, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
