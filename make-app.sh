#!/bin/zsh
# 打包成 LyricOverlay.app 并安装到 /Applications
set -e
cd "${0:A:h}"
swift build -c release
APP=build/LyricOverlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LyricOverlay "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.gao.LyricOverlay</string>
  <key>CFBundleName</key><string>LyricOverlay</string>
  <key>CFBundleDisplayName</key><string>歌词翻译</string>
  <key>CFBundleExecutable</key><string>LyricOverlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>抓取 Apple Music 窗口以识别歌词位置</string>
</dict></plist>
PLIST
# 用固定的开发证书签名: 权限按证书+Bundle ID 记录, 重新编译后不会失效 (临时签名每次都会失效)
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}
codesign --force --sign "${SIGN_ID:--}" --identifier com.gao.LyricOverlay "$APP"
pkill -x LyricOverlay || true
rm -rf /Applications/LyricOverlay.app
cp -R "$APP" /Applications/
echo "已安装到 /Applications/LyricOverlay.app"
