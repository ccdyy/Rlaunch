#!/bin/bash
# Rlaunch 构建脚本：编译并组装 Rlaunch.app（无签名 / ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
# --disable-sandbox: 本机 SPM 沙箱在当前 shell 环境不可用
swift build -c "$CONFIG" --product Rlaunch --disable-sandbox

# 生成并打包应用图标；CI 无 Pillow 时复用已提交的 icns/png
if python3 -c "import PIL" 2>/dev/null; then
    python3 Resources/generate_icon.py
elif [ -f Resources/AppIcon.icns ] && [ -f Resources/MenuBarIcon.png ]; then
    echo "跳过图标生成（使用已有 Resources/AppIcon.*）"
else
    echo "error: 需要 Pillow 生成图标，或提交 Resources/AppIcon.icns" >&2
    exit 1
fi

# 版本号：优先取最近的 git tag（v0.1.6 → 0.1.6），并附带提交描述便于定位构建
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -z "$VERSION" ] && VERSION="1.0.0"
BUILD_DESC="$(git describe --tags --always --dirty 2>/dev/null || true)"
[ -z "$BUILD_DESC" ] && BUILD_DESC="$VERSION"
echo "版本号：$VERSION ($BUILD_DESC)"

APP="Rlaunch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN=".build/$CONFIG/Rlaunch"
if [ ! -x "$BIN" ]; then
    echo "error: 未找到 $BIN" >&2
    exit 1
fi
cp "$BIN" "$APP/Contents/MacOS/Rlaunch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Rlaunch</string>
	<key>CFBundleIdentifier</key>
	<string>com.rlaunch.app</string>
	<key>CFBundleName</key>
	<string>Rlaunch</string>
	<key>CFBundleDisplayName</key>
	<string>Rlaunch</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>__VERSION__</string>
	<key>CFBundleVersion</key>
	<string>__BUILD_DESC__</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# 注入 tag 版本与构建描述
/usr/bin/sed -i '' -e "s|__VERSION__|$VERSION|" -e "s|__BUILD_DESC__|$BUILD_DESC|" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "✅ 构建完成: $APP"
