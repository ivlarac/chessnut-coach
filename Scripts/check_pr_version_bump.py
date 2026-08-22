#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

PROJECT_FILE = "ChessnutCoach.xcodeproj/project.pbxproj"


def unique_value(text: str, key: str) -> str:
    values = re.findall(rf"\b{re.escape(key)}\s*=\s*([^;]+);", text)
    values = [value.strip() for value in values]
    unique = sorted(set(values))
    if len(unique) != 1:
        raise SystemExit(
            f"Expected exactly one effective {key} value, found: {unique or 'none'}"
        )
    return unique[0]


def semantic_version(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value)
    if not match:
        raise SystemExit(f"Invalid MARKETING_VERSION: {value}")
    return tuple(map(int, match.groups()))


def integer_version(value: str) -> int:
    if not value.isdigit():
        raise SystemExit(f"Invalid CURRENT_PROJECT_VERSION: {value}")
    return int(value)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check_pr_version_bump.py <base-branch>")

    base_branch = sys.argv[1]
    base_ref = f"origin/{base_branch}:{PROJECT_FILE}"
    try:
        base_text = subprocess.check_output(
            ["git", "show", base_ref], text=True, stderr=subprocess.STDOUT
        )
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Could not read {base_ref}:\n{error.output}") from error

    head_text = Path(PROJECT_FILE).read_text()

    base_marketing = semantic_version(unique_value(base_text, "MARKETING_VERSION"))
    head_marketing = semantic_version(unique_value(head_text, "MARKETING_VERSION"))
    expected_marketing = (base_marketing[0], base_marketing[1], base_marketing[2] + 1)

    if head_marketing != expected_marketing:
        expected = ".".join(map(str, expected_marketing))
        actual = ".".join(map(str, head_marketing))
        base = ".".join(map(str, base_marketing))
        raise SystemExit(
            f"Each PR must bump the patch version exactly once: {base} -> {expected}; found {actual}."
        )

    base_build = integer_version(unique_value(base_text, "CURRENT_PROJECT_VERSION"))
    head_build = integer_version(unique_value(head_text, "CURRENT_PROJECT_VERSION"))
    if head_build != base_build + 1:
        raise SystemExit(
            "CURRENT_PROJECT_VERSION must also increase exactly once per PR: "
            f"{base_build} -> {base_build + 1}; found {head_build}."
        )

    print(
        "Version bump OK: "
        f"{'.'.join(map(str, base_marketing))} -> {'.'.join(map(str, head_marketing))} "
        f"(build {base_build} -> {head_build})"
    )


if __name__ == "__main__":
    main()
