#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 这是显式的本地开发构建：不尝试其他签名身份，也不绕过隔离检查。
CONFIGURATION="${AUXMO_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "不支持的构建配置：$CONFIGURATION" >&2; exit 1 ;;
esac
./Scripts/archive-legacy-build.sh
OUTPUT_DIR="${AUXMO_BUILD_OUTPUT_ROOT:-dist/build}/$CONFIGURATION"
APP_NAME="Auxmo"
if [[ "$CONFIGURATION" == "debug" ]]; then APP_NAME="Auxmo (develop)"; fi
APP_BUNDLE_NAME="$APP_NAME.app"
./Scripts/assert-app-idle.sh "$OUTPUT_DIR/$APP_BUNDLE_NAME"
swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$OUTPUT_DIR"
# 先在独立目录构建并验证完整包，不能往上次的包里增量拷贝而夹带旧文件。
STAGING="$(mktemp -d "$OUTPUT_DIR/.auxmo-build.XXXXXX")"
APP="$STAGING/$APP_BUNDLE_NAME"
cleanup() {
    local status=$?
    if [[ -e "$STAGING/previous.app" ]]; then
        echo "构建替换未完成，已保留上次构建：$STAGING/previous.app" >&2
        return 1
    fi
    rm -rf "$STAGING"
    return "$status"
}
trap cleanup EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Helpers"
cp "$BIN_DIR/Auxmo" "$APP/Contents/MacOS/Auxmo"
cp "$BIN_DIR/AuxmoUpdateHelper" "$APP/Contents/Helpers/AuxmoUpdateHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 开发包明确标记为 Auxmo (develop)，正式包保持 Auxmo，避免 Dock 中出现多个同名图标。
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
if [[ "$CONFIGURATION" == "debug" ]]; then
    # 开发版必须有独立身份，避免 Launch Services、偏好设置和系统授权与正式版混淆。
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.colin0v0.auxmo.develop" "$APP/Contents/Info.plist"
fi
# 更新仓库地址从当前 Git remote 注入最终应用包，避免源码或资源文件写死账号名。
REMOTE_URL="$(git remote get-url origin)"
UPDATE_REPOSITORY="$(printf '%s' "$REMOTE_URL" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
case "$UPDATE_REPOSITORY" in
    */*) ;;
    *) echo "无法从 origin 识别 GitHub 仓库：$REMOTE_URL" >&2; exit 1 ;;
esac
/usr/libexec/PlistBuddy -c "Add :AuxmoUpdateRepository string $UPDATE_REPOSITORY" "$APP/Contents/Info.plist"
# SwiftPM 在部分工具链上会把资源包输出成平面目录，导致 Bundle.module 无法识别。
# 这里不复制工具链产物，而是从源码资源确定性地构造标准 macOS bundle 结构。
RESOURCE_BUNDLE="$APP/Contents/Resources/Auxmo_Auxmo.bundle"
rm -rf "$RESOURCE_BUNDLE"
mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
cp Resources/Auxmo_Auxmo.bundle/Contents/Info.plist "$RESOURCE_BUNDLE/Contents/Info.plist"
cp -R Sources/Auxmo/Resources/. "$RESOURCE_BUNDLE/Contents/Resources/"
# 品牌图标必须随应用包一起复制，Finder 与 Dock 才能读取用户指定的 App 图标。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 许可声明是分发必需品；缺失时构建失败，不生成缺声明的应用。
cp LICENSE "$APP/Contents/Resources/Licenses/Auxmo-LICENSE.txt"
cp ThirdParty/HeadBridge/LICENSE "$APP/Contents/Resources/Licenses/HeadBridge-LICENSE.txt"
cp ThirdParty/PodsControl/LICENSE "$APP/Contents/Resources/Licenses/PodsControl-LICENSE.txt"
cp ThirdParty/SonyULTCtl/LICENSE "$APP/Contents/Resources/Licenses/SonyULTCtl-LICENSE.txt"
cp ThirdParty/BoseCtl/LICENSE "$APP/Contents/Resources/Licenses/BoseCtl-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP/Contents/Helpers/AuxmoUpdateHelper"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
DESTINATION="$OUTPUT_DIR/$APP_BUNDLE_NAME"
# 编译期间用户可能打开了上次的包；替换前再次确认，不能移动运行中的 bundle。
./Scripts/assert-app-idle.sh "$DESTINATION"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
mv "$APP" "$DESTINATION"
rm -rf "$STAGING/previous.app"
APP="$DESTINATION"
printf '本地应用已生成：%s/%s\n' "$PWD" "$APP"
