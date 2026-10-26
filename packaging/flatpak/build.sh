#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
: "${FLATPAK_FLUTTER:?Set FLATPAK_FLUTTER to the pinned flatpak-flutter.py path; see packaging/README.md}"
output="$root/app/build/flatpak"
mkdir -p "$output"
# Building the checked-out commit also covers unpublished repositories and PR merge commits.
python3 - "$root" "$output" <<'PY'
import subprocess
import sys
from pathlib import Path

import yaml

root, output = map(Path, sys.argv[1:])
manifest = yaml.safe_load((root / "packaging/flatpak/flatpak-flutter.yml").read_text())
manifest["modules"][0]["sources"][0] = {
    "type": "git",
    "url": root.as_uri(),
    "commit": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
}
(output / "flatpak-flutter.yml").write_text(yaml.safe_dump(manifest, sort_keys=False))
PY
cd "$output"
python3 "$FLATPAK_FLUTTER" flatpak-flutter.yml
if command -v flatpak-builder >/dev/null 2>&1; then
    flatpak-builder --user --force-clean --sandbox --repo=repo build one.jiri.easytimer.yml
else
    flatpak run org.flatpak.Builder --user --force-clean --sandbox --repo=repo build one.jiri.easytimer.yml
fi
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo repo easytimer.flatpak one.jiri.easytimer master
