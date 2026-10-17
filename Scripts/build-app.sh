#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_PATH="$ROOT_DIR/dist/MacCoffee.app"
CONTENTS_PATH="$APP_PATH/Contents"
HELPER_PATH="$CONTENTS_PATH/Library/HelperTools/MacCoffeeLidAwakeHelper"
LAUNCH_DAEMON_PATH="$CONTENTS_PATH/Library/LaunchDaemons/com.moey823.MacCoffee.LidAwake.plist"

cd "$ROOT_DIR"
swift build -c release
rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources" \
  "$CONTENTS_PATH/Library/HelperTools" "$CONTENTS_PATH/Library/LaunchDaemons"
cp "$ROOT_DIR/.build/release/MacCoffee" "$CONTENTS_PATH/MacOS/MacCoffee"
cp "$ROOT_DIR/.build/release/MacCoffeeLidAwakeHelper" "$HELPER_PATH"
chmod 755 "$CONTENTS_PATH/MacOS/MacCoffee" "$HELPER_PATH"

ICONSET_PATH="$CONTENTS_PATH/Resources/MacCoffee.iconset"
/usr/bin/swift "$ROOT_DIR/Scripts/generate-app-icon.swift" "$ICONSET_PATH"
/usr/bin/iconutil --convert icns "$ICONSET_PATH" --output "$CONTENTS_PATH/Resources/MacCoffee.icns"
rm -rf "$ICONSET_PATH"

cat > "$CONTENTS_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MacCoffee</string>
    <key>CFBundleIdentifier</key>
    <string>com.moey823.MacCoffee</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mac Coffee</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Coffee</string>
    <key>CFBundleIconFile</key>
    <string>MacCoffee.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$LAUNCH_DAEMON_PATH" <<'DAEMON'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.moey823.MacCoffee.LidAwake</string>
    <key>BundleProgram</key>
    <string>Contents/Library/HelperTools/MacCoffeeLidAwakeHelper</string>
    <key>MachServices</key>
    <dict>
        <key>com.moey823.MacCoffee.LidAwake</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
DAEMON

/usr/bin/codesign --force --sign - --timestamp=none "$HELPER_PATH"
/usr/bin/codesign --verify --strict "$HELPER_PATH"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf 'Built and ad-hoc signed: %s\n' "$APP_PATH"
