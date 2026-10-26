#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# GitHub Pages serves the custom domain at /; bundled resources avoid third-party requests.
flutter build web --release --no-web-resources-cdn --base-href / "$@"
find build/web/canvaskit -maxdepth 1 \( -name 'skwasm*' -o -name 'wimp*' -o -name 'webparagraph' \) -exec rm -rf {} +
find build/web/canvaskit -name '*.symbols' -delete

# The engine otherwise fetches its default font from Google Fonts.
fonts="$(flutter --version --machine | python3 -c 'import json, sys; print(json.load(sys.stdin)["flutterRoot"])')/bin/cache/artifacts/material_fonts"
roboto=build/web/assets/fonts/roboto
mkdir -p "$roboto"
for weight in Regular Medium Bold; do
    cp "$fonts/Roboto-$weight.ttf" "$roboto/"
done
cp "$fonts/Roboto_LICENSE.txt" "$roboto/LICENSE.txt"
python3 - <<'PY'
import json
from pathlib import Path

manifest = Path("build/web/assets/FontManifest.json")
families = [family for family in json.loads(manifest.read_text()) if family["family"] != "Roboto"]
families.append({
    "family": "Roboto",
    "fonts": [
        {"asset": "fonts/roboto/Roboto-Regular.ttf"},
        {"asset": "fonts/roboto/Roboto-Medium.ttf", "weight": 500},
        {"asset": "fonts/roboto/Roboto-Bold.ttf", "weight": 700},
    ],
})
manifest.write_text(json.dumps(families) + "\n")
PY
mkdir -p build/web/licenses
cp ../LICENSE build/web/licenses/GPL-3.0-only.txt
cp ../packaging/licenses/interval-timer-MIT.txt build/web/licenses/
