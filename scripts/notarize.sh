#!/usr/bin/env bash
#
# notarize.sh — NextStep Developer ID 签名 + 公证 + DMG 打包
#
# 用法：
#   1. 编辑下面的 CONFIG 段填入你的 Developer ID 和 Apple ID 凭证（或通过
#      环境变量覆盖）。
#   2. 一次性创建 notarytool profile（钥匙串里留下 app-specific password）：
#        xcrun notarytool store-credentials "NextStep-Notary" \
#            --apple-id "you@example.com" \
#            --team-id "ABCDE12345" \
#            --password "abcd-efgh-ijkl-mnop"
#   3. 运行：
#        ./scripts/notarize.sh
#   4. 成品：./dist/NextStep-<version>.dmg （已签名 + 已公证 + 已 staple）
#
# 先决条件：
#   - 一个 "Developer ID Application" 证书（不是 Mac Developer / Apple
#     Development）。Xcode → Settings → Accounts → Manage Certificates 创建。
#   - macOS 15+（脚本用的是 notarytool，legacy altool 已废弃）
#   - 已安装 create-dmg：  brew install create-dmg
#
# 输出目录结构：
#   ./build/   中间产物（archive、export 后的 .app）
#   ./dist/    对外分发的 .dmg 和校验和
#

set -euo pipefail

# =========================================================
# CONFIG — 填你的凭证（或设环境变量覆盖）
# =========================================================

PROJECT="NextStep.xcodeproj"
SCHEME="NextStep"
CONFIG="Release"

# Developer ID Application: 你的常见形态是
#   "Developer ID Application: Your Name (TEAMID12345)"
# 留空脚本会自动选择 keychain 里第一个匹配的，但推荐写全。
DEVELOPER_ID="${DEVELOPER_ID:-}"

# Team ID（10 位），用于 notarytool
TEAM_ID="${TEAM_ID:-}"

# notarytool 里保存的 keychain profile 名（见上面用法第 2 步）
NOTARY_PROFILE="${NOTARY_PROFILE:-NextStep-Notary}"

# Bundle ID 和产物名，从 pbxproj / Info.plist 读
BUNDLE_ID="com.claw.nextstep"
PRODUCT_NAME="NextStep"

# 版本号：优先从 Info.plist 里读 CFBundleShortVersionString；失败则问 git。
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          NextStep/Resources/Info.plist 2>/dev/null \
          || echo "0.1")"

BUILD_DIR="./build"
DIST_DIR="./dist"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${PRODUCT_NAME}.app"
DMG_PATH="${DIST_DIR}/${PRODUCT_NAME}-${VERSION}.dmg"
ENTITLEMENTS="NextStep/Resources/NextStep.entitlements"

# =========================================================
# 前置检查
# =========================================================

err() { printf "❌ %s\n" "$*" >&2; exit 1; }
info() { printf "▸ %s\n" "$*"; }
ok() { printf "✅ %s\n" "$*"; }

[ -d "$PROJECT" ] || err "找不到 $PROJECT，请在仓库根目录运行。"

# 检查沙盒开关 —— 公证前必须打开
if grep -A1 "com.apple.security.app-sandbox" "$ENTITLEMENTS" | grep -q "<false/>"; then
    cat <<EOF >&2
⚠️  $ENTITLEMENTS 里 app-sandbox 当前是 <false/>。

   生产分发 (Developer ID + 公证) 可以不开沙盒，但 App Store 必须开。
   如果你想走 App Store 通道：
     plutil -replace com.apple.security.app-sandbox -bool true $ENTITLEMENTS
   然后要重新评估：日历访问、iCloud Drive 路径访问、FSEvent 监听等是否仍可用。

   继续走 Developer ID 通道（不强制开沙盒）？ [y/N]
EOF
    read -r go
    [[ "$go" =~ ^[Yy]$ ]] || exit 1
fi

command -v xcrun       >/dev/null || err "没有 xcrun，请安装 Xcode command line tools。"
command -v create-dmg  >/dev/null || err "没有 create-dmg，请 brew install create-dmg。"

# 如果没写死 DEVELOPER_ID，尝试从 keychain 挑一个
if [ -z "$DEVELOPER_ID" ]; then
    DEVELOPER_ID="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    [ -n "$DEVELOPER_ID" ] || err "找不到 Developer ID Application 证书。"
    info "自动选择证书：$DEVELOPER_ID"
fi

[ -n "$TEAM_ID" ] || err "请设置 TEAM_ID（10 位 Team ID），或在脚本顶部填写。"

# =========================================================
# 1. 清理 + 归档
# =========================================================

info "清理 $BUILD_DIR $DIST_DIR …"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

info "xcodebuild archive ($CONFIG) …"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS='--options runtime --timestamp' \
    archive | tail -20

[ -d "$ARCHIVE_PATH" ] || err "archive 失败，未产出 $ARCHIVE_PATH"
ok "archive 完成"

# =========================================================
# 2. 导出 .app（Developer ID 分发）
# =========================================================

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

info "xcodebuild -exportArchive …"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" | tail -10

[ -d "$APP_PATH" ] || err "导出失败，未产出 $APP_PATH"
ok "export 完成：$APP_PATH"

# =========================================================
# 3. 验证签名 + hardened runtime
# =========================================================

info "验证签名 …"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" || err "签名验证失败"
codesign -dvv "$APP_PATH" 2>&1 | grep -q "flags=0x10000(runtime)" \
    || err "缺少 hardened runtime（--options runtime），公证会被拒"
ok "签名 + hardened runtime 已就位"

# =========================================================
# 4. 打 zip，提交公证
# =========================================================

NOTARY_ZIP="$BUILD_DIR/${PRODUCT_NAME}-notarize.zip"
info "打 zip 发送公证：$NOTARY_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

info "xcrun notarytool submit（同步等待结果，可能 1–5 分钟）…"
set +e
xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
NOTARY_STATUS=$?
set -e

if [ $NOTARY_STATUS -ne 0 ]; then
    info "公证失败。最近一次 log："
    SUBMISSION_ID="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
        | awk '/id:/ {print $2; exit}')"
    [ -n "$SUBMISSION_ID" ] && \
        xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE"
    err "notarize 失败，看上面的 log。常见原因：没开 hardened runtime / 有未签名子二进制 / entitlements 被 reject。"
fi
ok "公证通过"

# =========================================================
# 5. Staple
# =========================================================

info "xcrun stapler staple …"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
ok "staple 完成"

# =========================================================
# 6. 打 DMG
# =========================================================

info "制作 DMG：$DMG_PATH …"
create-dmg \
    --volname "$PRODUCT_NAME $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "$PRODUCT_NAME.app" 140 180 \
    --app-drop-link 400 180 \
    --hide-extension "$PRODUCT_NAME.app" \
    "$DMG_PATH" \
    "$APP_PATH" \
    || err "create-dmg 失败"

# DMG 本身也要签名并公证
info "对 DMG 再签名 …"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

info "DMG 也提交公证 …"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# =========================================================
# 7. 校验和 + 总结
# =========================================================

shasum -a 256 "$DMG_PATH" > "${DMG_PATH}.sha256"

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 构建完成

   .app  : $APP_PATH
   .dmg  : $DMG_PATH
   sha256: $(cut -d' ' -f1 "${DMG_PATH}.sha256")

下一步：
   - 在一台从未跑过 ad-hoc 版本的干净 Mac 上挂载 DMG，拖进 Applications
   - 双击启动：不应该有 Gatekeeper 警告
   - 验证：xcrun stapler validate "$DMG_PATH"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
