#!/bin/zsh
# Builds every deliverable of the "Insel" icon from Icon.swift.
set -euo pipefail
cd "${0:A:h}"
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -sdk $SDKROOT -swift-version 5 -O -target arm64-apple-macosx15.0 Icon.swift -o icon

./icon master icon-1024.png 1024
for s in 512 256 128; do sips -z $s $s icon-1024.png --out icon-$s.png >/dev/null; done
# 64 / 32 / 16: pixel-snapped small masters (a plain downscale smears the bars)
for s in 64 32 16; do ./icon small icon-$s.png $s; done

rm -rf AppIcon.iconset && mkdir AppIcon.iconset
cp icon-16.png   AppIcon.iconset/icon_16x16.png
cp icon-32.png   AppIcon.iconset/icon_16x16@2x.png
cp icon-32.png   AppIcon.iconset/icon_32x32.png
cp icon-64.png   AppIcon.iconset/icon_32x32@2x.png
cp icon-128.png  AppIcon.iconset/icon_128x128.png
cp icon-256.png  AppIcon.iconset/icon_128x128@2x.png
cp icon-256.png  AppIcon.iconset/icon_256x256.png
cp icon-512.png  AppIcon.iconset/icon_256x256@2x.png
cp icon-512.png  AppIcon.iconset/icon_512x512.png
cp icon-1024.png AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "built AppIcon.icns"
