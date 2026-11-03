#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
output="$PWD/build"
app="$output/Payload/Shixu.app"
mkdir -p "$app"
test -f Shixu/ShixuLogo.png
xcrun --sdk iphoneos clang -arch arm64 -target arm64-apple-ios16.0 -isysroot "$sdk" \
 -fobjc-arc -fmodules -O2 -Wall -Wextra -Werror=unguarded-availability-new \
 -framework Foundation -framework UIKit -framework WebKit -framework AuthenticationServices \
 -framework SafariServices -framework Security Shixu/main.m -o "$app/Shixu"
cp Shixu/Info.plist "$app/Info.plist"
# SideStore builds before 2026-09-12 send the raw display name to Apple's
# ASCII-only App ID registration. Keep that name ASCII; localize the iOS label.
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Info.plist")"
[[ "$display_name" =~ ^[A-Za-z0-9][A-Za-z0-9\ ]*$ ]]
mkdir -p "$app/zh-Hant.lproj"
printf '"CFBundleDisplayName" = "拾序";\n' > "$app/zh-Hant.lproj/InfoPlist.strings"
plutil -lint "$app/zh-Hant.lproj/InfoPlist.strings"
plutil -insert DTPlatformName -string iphoneos "$app/Info.plist"
plutil -insert DTSDKName -string "iphoneos$(xcrun --sdk iphoneos --show-sdk-version)" "$app/Info.plist"
cp Shixu/ShixuLogo.png "$app/ShixuLogo.png"
for icon in '60x60@2x:120' '60x60@3x:180' '76x76:76' '76x76@2x:152' '83.5x83.5@2x:167'; do
 name="${icon%:*}"; size="${icon#*:}"
 sips -z "$size" "$size" Shixu/ShixuLogo.png --out "$app/AppIcon$name.png" >/dev/null
done
xcrun ibtool --compile "$app/LaunchScreen.storyboardc" --minimum-deployment-target 16.0 Shixu/LaunchScreen.storyboard
plutil -lint "$app/Info.plist"
# Ad-hoc packaging only: no Apple account, certificate, P12 or provisioning profile in CI.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
lipo -info "$app/Shixu"
(cd "$output" && /usr/bin/zip -q -r Shixu-unsigned.ipa Payload)
shasum -a 256 "$output/Shixu-unsigned.ipa" | tee "$output/SHA256SUMS.txt"
echo 'Build completed. The IPA still requires personal-device signing in the existing SideStore.'
