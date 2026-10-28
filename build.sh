#!/bin/bash
# Builds DeskBar.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=DeskBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DeskBar "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Apple's 3D MacBook Pro model isn't in the repository (it's Apple's, for personal use). If you've
# put a copy in Models/ it's bundled; otherwise DeskBar offers to download it from apple.com.
if [ -f Models/macbook-pro-14-space-black.usdz ]; then
    cp Models/macbook-pro-14-space-black.usdz "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
