#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WeChatExporter"
APP_DIR="$ROOT/${APP_NAME}.app"
BINARY="$ROOT/.build/release/WeChatExporter"
ICON_SRC="$ROOT/assets/AppIcon.icns"
ICON_PNG="$ROOT/assets/AppIcon.png"
WX_CLI_VERSION="${WX_CLI_VERSION:-vendor}"
APP_VERSION="${APP_VERSION:-2.14.0}"
APP_BUILD="${APP_BUILD:-32}"

echo "编译原生 macOS 应用…"
cd "$ROOT"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "打包内置 wx-cli…"
bash "$ROOT/scripts/bundle_wx_cli.sh" "$APP_DIR/Contents/Resources"
chmod +x "$APP_DIR/Contents/Resources/wx-cli"

# ffmpeg 供 wx-cli 把微信语音（SILK）转成 MP3，并解码 WXGF 动态表情；
# ffprobe 用来数 WXGF 帧数，缺了它动态表情出不来。
# 两者都缺失时 wx-cli 会自动降级导出原始 .silk / .wxgf，不会中断导出。
if [[ -f "$ROOT/vendor/macos/ffmpeg" ]]; then
  echo "打包内置 ffmpeg…"
  cp "$ROOT/vendor/macos/ffmpeg" "$APP_DIR/Contents/Resources/ffmpeg"
  chmod +x "$APP_DIR/Contents/Resources/ffmpeg"
  # LGPL v2.1 要求随分发提供许可证全文
  cp "$ROOT/vendor/macos/ffmpeg-COPYING.LGPLv2.1" "$APP_DIR/Contents/Resources/ffmpeg-COPYING.LGPLv2.1"
else
  echo "警告：未找到 vendor/macos/ffmpeg，语音将以原始 SILK 格式导出"
  echo "      执行 bash scripts/build_ffmpeg_minimal.sh 可构建它"
fi

if [[ -f "$ROOT/vendor/macos/ffprobe" ]]; then
  echo "打包内置 ffprobe…"
  cp "$ROOT/vendor/macos/ffprobe" "$APP_DIR/Contents/Resources/ffprobe"
  chmod +x "$APP_DIR/Contents/Resources/ffprobe"
else
  echo "警告：未找到 vendor/macos/ffprobe，WXGF 动态表情将无法输出动图"
fi

bash "$ROOT/scripts/prepare_icon.sh"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
elif [[ -f "$ICON_PNG" ]]; then
  echo "警告：未生成 AppIcon.icns，请在 macOS 上运行 scripts/prepare_icon.sh"
  echo "      当前环境无法生成正确尺寸的 macOS 图标。"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.wechat-exporter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>微信聊天记录导出</string>
    <key>CFBundleDisplayName</key>
    <string>微信聊天记录导出</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSRequiresNativeExecution</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <!--
      微信 CDN 上的表情、图片、视频几乎全是明文 http://（实测 44570 个 http 对 560 个 https），
      而 App Transport Security 默认拦截明文请求——不开例外的话表情会全数「网络错误」下载失败。
      这里只对腾讯 / 微信的 CDN 根域放行，不使用 NSAllowsArbitraryLoads 全局关闭。
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>qq.com</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>qpic.cn</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>qlogo.cn</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>wechat.com</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>tenpay.com</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>gtimg.com</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "完成: $APP_DIR"
echo ""
echo "可选：生成 DMG 安装包"
echo "  bash scripts/create_dmg.sh"
