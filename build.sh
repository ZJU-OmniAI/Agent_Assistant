#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name="Agent Assistant.app"
contents="$work/$name/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" dist
for arch in arm64 x86_64; do
    ./swiftc.sh -swift-version 5 -Osize -whole-module-optimization -parse-as-library \
        -target "$arch-apple-macos13.0" \
        Sources/*.swift -o "$work/$arch"
done
xcrun lipo -create "$work/arm64" "$work/x86_64" -output "$contents/MacOS/AgentAssistant"
cp Info.plist "$contents/"
iconutil -c icns assets/AppIcon.iconset -o "$contents/Resources/AppIcon.icns"
plutil -lint "$contents/Info.plist"
if [ -n "${AGENT_ASSISTANT_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$AGENT_ASSISTANT_SIGN_IDENTITY" "$work/$name"
else
    ./signing.sh "$work/$name"
fi
codesign --verify --strict "$work/$name"
rm -rf "dist/$name"
ditto "$work/$name" "dist/$name"
codesign --verify --strict "dist/$name"
echo "已构建：$(pwd)/dist/$name"
