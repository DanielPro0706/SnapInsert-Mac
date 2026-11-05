#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/notarized.app /path/to/output-directory" >&2
    exit 64
fi

app_source="$1"
release_directory="$2"
if [ ! -d "$app_source/Contents" ]; then
    echo "The first argument must be an exported macOS app." >&2
    exit 66
fi

/usr/bin/codesign --verify --deep --strict "$app_source"
/usr/bin/xcrun stapler validate "$app_source"
architecture=$(/usr/bin/lipo -archs "$app_source/Contents/MacOS/SnapInsertMac")
if [ "$architecture" != "arm64" ]; then
    echo "This package filename is reserved for the Apple Silicon build." >&2
    exit 65
fi

mkdir -p "$release_directory"
release_directory=$(cd "$release_directory" && pwd)
for filename in SnapInsert-Mac-AppleSilicon.dmg SnapInsert-Mac-AppleSilicon.zip SHA256SUMS.txt; do
    if [ -e "$release_directory/$filename" ]; then
        echo "Output already exists; choose an empty output directory: $filename" >&2
        exit 73
    fi
done

stage_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/SnapInsert-package.XXXXXX")
/usr/bin/ditto "$app_source" "$stage_directory/SnapInsert.app"
/usr/bin/codesign --verify --deep --strict "$stage_directory/SnapInsert.app"
/usr/bin/xcrun stapler validate "$stage_directory/SnapInsert.app"
/bin/ln -s /Applications "$stage_directory/Applications"
app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_source/Contents/Info.plist")
printf "SnapInsert %s — Mac 接收器\n" "$app_version" > "$stage_directory/安装说明.txt"
/bin/cat >> "$stage_directory/安装说明.txt" <<'INSTALL'

系统要求：macOS 14 或更新版本，Apple Silicon（M 系列）Mac。

1. 将 SnapInsert.app 拖入 Applications（应用程序）。
2. 打开 SnapInsert，在屏幕顶部菜单栏点击相机图标。
3. 填写测试群组邀请码，激活中转服务，并按界面提示授予辅助功能权限。
4. 在 iPhone 的配套 SnapInsert 中扫描 Mac 配对二维码。
5. 在 Mac 的目标应用点好插入位置，iPhone 拍照并确认使用照片。

Mac 接收器需保持运行，目标应用需支持图片粘贴。
两端只需联网，不要求局域网设备互相访问。
照片和回执端到端加密，中转服务器不保存照片或内容日志。
配对码包含密钥，请勿分享；系统或第三方剪贴板工具可能保留历史。

应用已使用 Developer ID 签名并通过 Apple 公证。
源代码与使用说明：https://github.com/DanielPro0706/SnapInsert-Mac
INSTALL

/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$stage_directory/SnapInsert.app" "$release_directory/SnapInsert-Mac-AppleSilicon.zip"

# The app carries its own Developer ID signature and stapled notarization ticket.
# The DMG is a plain container; no separate container notarization is claimed.
if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
    /usr/sbin/diskutil image create from --format UDZO --volumeName SnapInsert \
        "$stage_directory" "$release_directory/SnapInsert-Mac-AppleSilicon.dmg"
else
    /usr/bin/hdiutil create -volname SnapInsert -srcfolder "$stage_directory" \
        -format UDZO "$release_directory/SnapInsert-Mac-AppleSilicon.dmg"
fi

(
    cd "$release_directory"
    /usr/bin/shasum -a 256 SnapInsert-Mac-AppleSilicon.dmg SnapInsert-Mac-AppleSilicon.zip > SHA256SUMS.txt
)
echo "Packages: $release_directory"
echo "Staging retained for inspection: $stage_directory"
