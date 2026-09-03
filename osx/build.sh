#!/usr/bin/env bash
# Regenerates the Xcode project and builds it, unsigned, into build/ —
# the same script local dev and CI both use, so their output layout matches.
#
# Usage: ./build.sh [Debug|Release]   (defaults to Debug)
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="${1:-Debug}"

xcodegen generate

xcodebuild -project OnePasshole.xcodeproj -scheme OnePasshole \
  -configuration "$CONFIGURATION" -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="build/Build/Products/$CONFIGURATION/1passhole.app"
echo ""
echo "Built: osx/$APP_PATH"
