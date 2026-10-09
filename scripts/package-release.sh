#!/usr/bin/env bash
# 在本机用固定证书构建 Apple Silicon Release，只打包，不安装或运行测试。
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == "Darwin" ]] || { echo "需要 macOS 和 Xcode。" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "请先安装 XcodeGen。" >&2; exit 1; }

xcodegen generate --quiet
xcodebuild -project Chatbot.xcodeproj -scheme Chatbot -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -quiet build

app="build/Build/Products/Release/Chatbot.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
archive="Chatbot-${version}-macOS-arm64.zip"
output="build/releases"
mkdir -p "$output"
[[ ! -e "$output/$archive" ]] || { echo "安装包已存在：$output/$archive；请先移走旧包。" >&2; exit 1; }
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(
    cd "$output"
    shasum -a 256 "$archive" > "$archive.sha256"
)
echo "安装包：$output/$archive"
echo "校验文件：$output/$archive.sha256"
