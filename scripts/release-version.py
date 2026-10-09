#!/usr/bin/env python3
"""Choose a patch release from Git tags; reuse a version when retrying a commit."""

import plistlib
import re
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args], text=True).splitlines()


def parse_version(value):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?", value):
        raise ValueError(f"Unsupported version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts if len(parts) == 3 else (*parts, 0)


def release_tags(tags):
    return [tag for tag in tags if re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)]


def main():
    current = release_tags(git("tag", "--points-at", "HEAD"))
    if current:
        version = max(parse_version(tag[1:]) for tag in current)
    else:
        with open("Info.plist", "rb") as source:
            baseline = parse_version(plistlib.load(source)["CFBundleShortVersionString"])
        versions = [parse_version(tag[1:]) for tag in release_tags(git("tag", "--list"))]
        major, minor, patch = max([baseline, *versions])
        version = major, minor, patch + 1
    value = ".".join(map(str, version))
    print(f"version={value}")
    print(f"tag=v{value}")


if __name__ == "__main__":
    main()
