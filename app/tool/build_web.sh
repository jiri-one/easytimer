#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# GitHub Pages serves the custom domain at /; bundled resources avoid third-party requests.
flutter build web --release --no-web-resources-cdn --base-href / "$@"
find build/web/canvaskit -maxdepth 1 \( -name 'skwasm*' -o -name 'wimp*' -o -name 'webparagraph' \) -exec rm -rf {} +
find build/web/canvaskit -name '*.symbols' -delete

# Preserve the pubspec font aliases so web and native use the same glyphs.
python3 - <<'PYFONT'
import json
from pathlib import Path

manifest = json.loads(Path("build/web/assets/FontManifest.json").read_text())
families = {family["family"]: family["fonts"] for family in manifest}
assert families["Roboto"] == families["DroidSansMono"]
for fonts in families.values():
    for font in fonts:
        assert (Path("build/web/assets") / font["asset"]).is_file()
PYFONT
mkdir -p build/web/licenses
cp ../LICENSE build/web/licenses/GPL-3.0-only.txt
cp ../packaging/licenses/interval-timer-MIT.txt build/web/licenses/
cp ../NOTICE build/web/licenses/NOTICE.txt
cp assets/licenses/DroidSansMono-Apache-2.0.txt build/web/licenses/
