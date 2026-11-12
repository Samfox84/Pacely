#!/bin/bash
# Builds Pacely for Mac (works on both Apple silicon and Intel) and puts it in your Applications folder.
cd "$(dirname "$0")"
echo "Building Pacely for Mac… (about a minute)"
if [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is needed. Install it from the App Store, open it once, then run this again."; exit 1
fi
rm -rf build
xcodebuild -project PacelyMac.xcodeproj -target PacelyMac -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO SYMROOT="$PWD/build" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" -quiet 2>&1 | grep -E "error:|BUILD" | head -20
APP="build/Release/Pacely.app"
if [ ! -d "$APP" ]; then
  echo; echo "!! The build didn't finish. Take a screenshot of this window and send it to Claude."; exit 1
fi
mkdir -p ~/Applications
pkill -x Pacely 2>/dev/null; sleep 1
rm -rf ~/Applications/Pacely.app
cp -R "$APP" ~/Applications/
echo; echo "=================================================="
echo " Pacely is installed in your Applications folder"
echo " $(lipo -archs ~/Applications/Pacely.app/Contents/MacOS/Pacely | sed 's/x86_64/Intel/;s/arm64/Apple silicon/') "
echo "=================================================="
open ~/Applications/Pacely.app
