#!/usr/bin/env bash
# Fail before signing/notarizing if the app or any bundled Sparkle executable loses a slice.
set -euo pipefail
app="${1:?Usage: scripts/check-universal.sh path/to/dinky.app}"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
for binary in \
  "$app/Contents/MacOS/dinky" \
  "$sparkle/Sparkle" \
  "$sparkle/Autoupdate" \
  "$sparkle/Updater.app/Contents/MacOS/Updater" \
  "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
  # Verify separately: some Apple lipo versions reject a multi-architecture verification.
  lipo "$binary" -verify_arch arm64
  lipo "$binary" -verify_arch x86_64
done
