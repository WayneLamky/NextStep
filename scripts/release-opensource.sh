#!/usr/bin/env bash
#
# release-opensource.sh — 开源分发用，免 Developer ID 的构建流水线
#
# 用途：本地或 GitHub Actions 里跑，产出一个 ad-hoc 签名的 DMG。
# 用户下载后运行一句命令（见 README）就能跑，不需要你掏 $99/年。
#
# 用法：
#   ./scripts/release-opensource.sh
#
# 产物：
#   ./dist/NextStep-<version>.dmg
#   ./dist/NextStep-<version>.dmg.sha256
#
# 和 notarize.sh 的区别：
#   - 不需要 Developer ID Application 证书
#   - 不需要 Apple Notary
#   - 不加 --options runtime（hardened runtime 只有配合 notarize 才有意义）
#   - 用 "-" 做 ad-hoc 签名（codesign 的本地免费签名）
#

set -euo pipefail

# =========================================================
# CONFIG
# =========================================================

PROJECT="NextStep.xcodeproj"
SCHEME="NextStep"
CONFIG="Release"
PRODUCT_NAME="NextStep"

# 版本号从 pbxproj 里的 MARKETING_VERSION 读（Info.plist 里是
# `$(MARKETING_VERSION)` 字面量，需要 Xcode 展开，源文件读出来会错）。
# 多 target 工程会有多行相同，去重后取第一个。
VERSION="$(grep -E 'MARKETING_VERSION = [0-9]' "${PROJECT}/project.pbxproj" \
          | head -1 | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' ' \
          || echo "dev")"
VERSION="${VERSION:-dev}"

BUILD_DIR="./build"
DIST_DIR="./dist"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${PRODUCT_NAME}.app"
DMG_PATH="${DIST_DIR}/${PRODUCT_NAME}-${VERSION}.dmg"

# =========================================================
# 前置检查
# =========================================================

err()  { printf "❌ %s\n" "$*" >&2; exit 1; }
info() { printf "▸ %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }

[ -d "$PROJECT" ] || err "找不到 $PROJECT，请在仓库根目录运行。"
command -v xcrun      >/dev/null || err "没有 xcrun，请装 Xcode command line tools。"
command -v create-dmg >/dev/null || err "没有 create-dmg，请 brew install create-dmg。"

# =========================================================
# 1. 清理 + archive
# =========================================================

info "清理 $BUILD_DIR $DIST_DIR …"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

info "xcodebuild archive ($CONFIG, ad-hoc 签名) …"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    archive | tail -20

[ -d "$ARCHIVE_PATH" ] || err "archive 失败，未产出 $ARCHIVE_PATH"
ok "archive 完成"

# =========================================================
# 2. 直接从 archive 里把 .app 拷出来（不走 exportArchive，
#    因为 exportArchive 对无证书的导出方法支持不好）
# =========================================================

info "从 archive 提取 .app …"
mkdir -p "$EXPORT_DIR"
cp -R "${ARCHIVE_PATH}/Products/Applications/${PRODUCT_NAME}.app" "$APP_PATH"

# =========================================================
# 3. Ad-hoc 重签（确保 bundle 内所有可执行文件都被签）
# =========================================================

info "ad-hoc 重签（identity = \"-\"）…"
codesign --remove-signature "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign "-" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || err "ad-hoc 签名校验失败"
ok ".app 已 ad-hoc 签名"

# =========================================================
# 4. 打 DMG（DMG 本身不签）
# =========================================================

info "制作 DMG → $DMG_PATH …"
create-dmg \
    --volname "${PRODUCT_NAME} ${VERSION}" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "${PRODUCT_NAME}.app" 140 180 \
    --app-drop-link 400 180 \
    --hide-extension "${PRODUCT_NAME}.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" \
    || err "create-dmg 失败"

# =========================================================
# 5. 校验和 + 总结
# =========================================================

shasum -a 256 "$DMG_PATH" > "${DMG_PATH}.sha256"
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 开源发布构建完成

   .dmg      : $DMG_PATH
   大小      : $DMG_SIZE
   sha256    : $(cut -d' ' -f1 "${DMG_PATH}.sha256")

用户下载后要跑的命令（写进 README）：
   xattr -cr /Applications/${PRODUCT_NAME}.app

然后双击启动即可。首次打开系统会弹"无法验证开发者"，
用户去「系统设置 → 隐私与安全性」点"仍要打开"即可；
或跑上面这句 xattr 一步到位。
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
