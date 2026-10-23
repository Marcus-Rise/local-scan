#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="${1:-dist/Local Scan.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path .build-cache Sources/ScannerCore.swift Sources/LocalScan.swift -o "$APP/Contents/MacOS/LocalScan"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalScan</string>
<key>CFBundleIdentifier</key><string>io.github.marcus-rise.local-scan</string>
<key>CFBundleName</key><string>Локальный сканер</string>
<key>CFBundleDisplayName</key><string>Локальный сканер</string>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>CFBundleLocalizations</key><array><string>ru</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Сканирование документов напрямую со сканера в домашней сети.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
codesign --force --sign - "$APP"
