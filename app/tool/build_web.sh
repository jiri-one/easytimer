#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# Older builds left duplicate licences outside the Flutter asset bundle.
rm -rf build/web/licenses
# GitHub Pages serves the custom domain at /; bundled resources avoid third-party requests.
flutter build web --release --no-web-resources-cdn --base-href / "$@"
wasm=false
for argument in "$@"; do
  case "$argument" in
    --wasm) wasm=true ;;
    --no-wasm) wasm=false ;;
  esac
done
if [ "$wasm" = false ]; then
  find build/web/canvaskit -maxdepth 1 \( -name 'skwasm*' -o -name 'wimp*' -o -name 'webparagraph' \) -exec rm -rf {} +
fi
find build/web/canvaskit -name '*.symbols' -delete
