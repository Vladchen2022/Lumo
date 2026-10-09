#!/bin/bash
set -euo pipefail
LUMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LUMO_ROOT"
bash Scripts/build-app.sh
LUMO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Lumo.app/Contents/Info.plist)"
LUMO_ARCH="$(uname -m)"
LUMO_PACKAGE="Lumo-$LUMO_VERSION-macOS-$LUMO_ARCH"
LUMO_STAGE="$(mktemp -d "${TMPDIR:-/tmp/}lumo-export.XXXXXX")"
trap 'rm -rf "$LUMO_STAGE"' EXIT
mkdir -p "$LUMO_STAGE/$LUMO_PACKAGE" "$LUMO_ROOT/dist"
ditto dist/Lumo.app "$LUMO_STAGE/$LUMO_PACKAGE/Lumo.app"
cp LICENSE "$LUMO_STAGE/$LUMO_PACKAGE/LICENSE"
cat > "$LUMO_STAGE/$LUMO_PACKAGE/安装说明.txt" <<'INSTALL'
Lumo — 抽象构成与图像解构工具

要求 macOS 14 及以上版本、Apple Silicon Mac。
将 Lumo.app 拖到“应用程序”文件夹，然后打开。
应用使用本机临时签名，尚未进行 Developer ID 签名和 Apple 公证。

源码：https://github.com/Vladchen2022/Lumo
使用说明及已知限制见仓库 README。
本软件以 MIT 许可证开源，完整条款见随附 LICENSE。
INSTALL
LUMO_ZIP="$LUMO_ROOT/dist/$LUMO_PACKAGE.zip"
ditto -c -k --sequesterRsrc --keepParent "$LUMO_STAGE/$LUMO_PACKAGE" "$LUMO_ZIP"
cd "$LUMO_ROOT/dist"
shasum -a 256 "$LUMO_PACKAGE.zip" > "$LUMO_PACKAGE.zip.sha256"
echo "$LUMO_ZIP"
