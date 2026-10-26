#!/bin/sh
set -eu

if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf '%s\n' 'rsvg-convert is required to generate the EasyTimer icons.' >&2
    exit 1
fi

cd "$(dirname "$0")"
res=../app/android/app/src/main/res
web=../app/web
linux=../packaging/linux
background=$(sed -n 's/.*id="background".*fill="\([^"]*\)".*/\1/p' icon.svg)
test -n "$background"

png() {
    rsvg-convert --width "$2" --height "$2" --output "$3" "$1"
}

# Keep the complete mark inside Android's 66 dp safe circle.
sed \
    -e '/id="background"/d' \
    -e 's/id="stopwatch"/id="stopwatch" transform="translate(17.28 17.28) scale(0.68)"/' \
    icon.svg > icon-foreground.svg

# Maskable icons need opaque corners and a mark inside the 80% safe circle.
sed \
    -e 's/ rx="12"//' \
    -e 's/id="stopwatch"/id="stopwatch" transform="translate(5.4 5.4) scale(0.9)"/' \
    icon.svg > icon-maskable.svg

for density in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    name=${density%%:*}
    size=${density##*:}
    mkdir -p "$res/mipmap-$name"
    png icon.svg "$size" "$res/mipmap-$name/ic_launcher.png"
    png icon-foreground.svg "$((size * 9 / 4))" "$res/mipmap-$name/ic_launcher_foreground.png"
    cp "$res/mipmap-$name/ic_launcher_foreground.png" "$res/mipmap-$name/ic_launcher_monochrome.png"
done

mkdir -p "$res/mipmap-anydpi-v26" "$res/values"
cat > "$res/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
EOF
cat > "$res/values/ic_launcher_background.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">$background</color>
</resources>
EOF

mkdir -p "$web/icons" "$linux"
png icon.svg 32 "$web/favicon.png"
for size in 192 512; do
    png icon.svg "$size" "$web/icons/Icon-$size.png"
    png icon-maskable.svg "$size" "$web/icons/Icon-maskable-$size.png"
done

cp icon.svg "$linux/one.jiri.easytimer.svg"
for size in 16 24 32 48 64 128 256 512; do
    dir="$linux/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    png icon.svg "$size" "$dir/one.jiri.easytimer.png"
done

store=../app/fastlane/metadata/android/en-US/images
mkdir -p "$store"
png icon.svg 512 "$store/icon.png"
