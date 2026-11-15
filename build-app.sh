#!/bin/bash
# ------------------------------------------------------------------
# WhaleFloat 打包脚本
#
# 把 SwiftPM 的可执行文件打成标准 macOS .app bundle，装到 /Applications。
#
# 为什么要 .app 而不是裸可执行文件：
#   · 系统把它当正式应用对待（Dock/通知/权限归属都正常）
#   · Resources 有标准位置，素材随包走，不依赖外部路径
#   · launchd 可直接按 app 路径启动
# ------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WhaleFloat"
BUNDLE_ID="ai.dsh.whalefloat"
# 版本号从源码读。它在 AppInfo.swift 里，
# 原先在 Menu.swift —— 拆分文件后这里的路径没跟着改，
# 读不到就回退成 0.1.0，Finder 里于是看到旧版本。
# 用 grep -r 扫整个源码目录，以后再搬家也不会失效。
# 版本号整串读取，允许 -alpha / -beta 后缀。0.2.0 分期交付靠的就是这个后缀。
VERSION="$(grep -rhoE 'static let version = "[^"]+"' "$HERE/Sources/WhaleFloat/" 2>/dev/null \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -z "$VERSION" ] && VERSION="0.1.0"
# 装到系统的 /Applications —— Finder 侧边栏「应用程序」指向的是这里，
# 装到 ~/Applications 的话在侧边栏里看不到，也不符合拖进「应用程序」的直觉。
# 普通用户对 /Applications 有写权限，不需要 sudo。
# 默认装到 /Applications。设了 STAGE_DIR 就只组装到那个目录，不碰本机安装
# —— 发版打包用这条路径，避免把 ad-hoc 签名的包覆盖到开发机上（会重置 TCC 权限）。
DEST="${STAGE_DIR:-/Applications}/${APP_NAME}.app"

echo "▸ 编译 release 版本…"
cd "$HERE"
swift build -c release 2>&1 | tail -3

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "✗ 找不到可执行文件 $BIN"; exit 1; }

echo "▸ 组装 app bundle…"
if [ -n "${STAGE_DIR:-}" ]; then
  mkdir -p "$STAGE_DIR"
fi
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"

cp "$BIN" "$DEST/Contents/MacOS/${APP_NAME}"

# 素材随包走 —— 程序自足，不依赖 ~/.dsh 下的路径
# png=角色立绘  gif=摸摸头动画  mp3=按压音效  icns=应用图标
for ext in png gif mp3 wav icns; do
  for f in "$HERE/Resources/"*."$ext"; do
    [ -f "$f" ] && cp "$f" "$DEST/Contents/Resources/"
  done
done

# 彩蛋动画（HTML）。创意工坊会往 ~/.dsh/whalefloat-animations 放同名目录，
# 用户目录优先于这里 —— 所以包内这份只是出厂默认。
if [ -d "$HERE/Resources/animations" ]; then
  rm -rf "$DEST/Contents/Resources/animations"
  cp -R "$HERE/Resources/animations" "$DEST/Contents/Resources/animations"
  echo "  内置动画：$(ls "$HERE/Resources/animations" | tr '\n' ' ')"
fi

# 内置法定节假日数据（官方发布，见 HolidayCalendar.swift）。
# 随包放几年，离线也能用；联网后会自行更新到更新的年份。
if [ -d "$HERE/Resources/holidays" ]; then
  rm -rf "$DEST/Contents/Resources/holidays"
  cp -R "$HERE/Resources/holidays" "$DEST/Contents/Resources/holidays"
  echo "  内置节假日数据：$(ls "$HERE/Resources/holidays" | tr '\n' ' ')"
fi

# 素材来源与许可 —— 包内带素材，这份说明要跟着走
if [ -f "$HERE/NOTICE-ASSETS.md" ]; then
  cp "$HERE/NOTICE-ASSETS.md" "$DEST/Contents/Resources/NOTICE-assets.md"
  echo "  素材说明：NOTICE-assets.md"
fi

# 内置 launchd 模板 —— 首次运行时程序自己装自启，
# 这样从 DMG 拖进「应用程序」就能用，不需要再跑 install.sh。
cp "$HERE/ai.dsh.whalefloat.plist" "$DEST/Contents/Resources/launchagent.plist"

# 内置 DSH 启动器 —— 「启动 DSH GUI」菜单要用。
#
# 构建时从这份源码拷进包里；运行时优先用包内那份，找不到才回退到
# 工作区路径（见 DSHLauncher.scriptPath）。所以这台开发机上路径写死没关系，
# 打出来的包不依赖它 —— 换台机器照样能跑。
LAUNCHER_SRC="$HOME/dsh-workspace/.dsh/skills/dsh-launcher/scripts/dsh-launcher.sh"
if [ -f "$LAUNCHER_SRC" ]; then
  cp "$LAUNCHER_SRC" "$DEST/Contents/Resources/dsh-launcher.sh"
  echo "  内置启动器：dsh-launcher.sh"
fi

# 内置「中介」插件 —— 它们挂在 DSH 上采集事件，本程序读文件。
#
# 源从**项目目录**取，不是从 ~/.dsh/plugins/。
# 后者是安装目标：卸载脚本会把它清掉，从那里读会导致
# 「卸过一次之后，再构建出来的包里就没有插件了」。
#
# 0.2.1 起**默认不再内置**。插件已经上架，由市场分发、由市场升级，
# 再由插件负责把 app 装上 —— 要是 app 里还塞一份，两条安装路径会
# 互相覆盖，用户跟着失去升级能力。
#
# 更直接的问题：插件里内嵌着 app 的 tar.gz（2.4 MB），
# app 再内置插件，就成了 app 里装着 app —— 这一份纯属浪费，
# 而且会让人误以为「包里那份是正版」。
#
# 需要离线兜底时才设 BUNDLE_PLUGIN=1，把插件连同一份安装包塞进 app。
if [ "${BUNDLE_PLUGIN:-0}" = "1" ]; then
  mkdir -p "$DEST/Contents/Resources/plugins"
  for p in dsh-whalefloat-helper; do
    SRC_PLUGIN="$HERE/plugins/$p"
    if [ -d "$SRC_PLUGIN" ]; then
      rm -rf "$DEST/Contents/Resources/plugins/$p"
      cp -R "$SRC_PLUGIN" "$DEST/Contents/Resources/plugins/$p"
      echo "  内置插件：$p"
    else
      echo "  ⚠ 项目里缺少插件源码：$SRC_PLUGIN"
    fi
  done
else
  echo "  插件不入包（由插件市场分发；离线包设 BUNDLE_PLUGIN=1）"
fi

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>小鲸鱼</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <!-- 必须 >= 26：系统按「链接 SDK 版本」决定是否启用 Liquid Glass。
         写 13.0 时实测 NSPopover 给的是纯白底，不是系统材质。 -->
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <!-- 进 Dock，有图标（可在 Dock 上右键退出/切换） -->
    <key>LSUIElement</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 日历只在用户此前已授权时读取；应用不主动申请，但这把钥匙仍要有，
         否则 EventKit 读取会被直接拒绝。 -->
    <key>NSCalendarsUsageDescription</key>
    <string>仅在已授权时读取「中国大陆节假日」日历，用于判断峰谷计价；不主动申请，也不读个人日程。</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>仅在已授权时读取「中国大陆节假日」日历，用于判断峰谷计价；不主动申请，也不读个人日程。</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# 签名策略：本地构建与发布包分开。
#
#   本地构建（默认）    用自签名证书「WhaleFloat Dev」
#                       → TCC 认证书身份，反复构建也不会重置权限
#   发布包（RELEASE=1） 用 ad-hoc
#                       → 自签名证书不在用户机器上，分发出去反而多一层
#                         「未知证书」的恐吓提示。反正都要右键打开，
#                         ad-hoc 更干脆。
#
# 另一个事实：分发的 app 不会重建，CDHash 固定，权限本来就稳定 ——
# 「权限反复要」只是开发期的现象。
SIGN_ID="WhaleFloat Dev"

if [ "${RELEASE:-0}" = "1" ]; then
    echo "▸ 签名（发布包：ad-hoc）…"
    codesign --force --deep --sign - "$DEST" 2>&1 | tail -1 \
        || echo "（签名跳过，本地运行不受影响）"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "▸ 签名（本地构建：$SIGN_ID）…"
    codesign --force --deep --sign "$SIGN_ID" "$DEST" 2>&1 | tail -1 \
        || echo "（签名失败，回退 ad-hoc）"
else
    echo "▸ 签名（未找到证书，回退 ad-hoc）…"
    codesign --force --deep --sign - "$DEST" 2>&1 | tail -1 \
        || echo "（签名跳过，本地运行不受影响）"
fi
echo "  运行：open "$DEST""
# ------------------------------------------------------------------
# 把刚打好的 app 打成插件用的内嵌安装包。
#
# 只有在「发布打包」时做（RELEASE=1 且指定了 STAGE_DIR）：
# 本地构建装到 /Applications 供日常使用，不该反过来改动仓库里的产物。
#
# 为什么在构建脚本里做、而不是手工打：这两个文件必须跟着同一次构建走。
# 手打漏一次，就会出现「源码 0.2.2、插件里躺的还是 0.2.1」——
# 用户点上架按钮装到的还是旧版，而界面上一切正常，极难察觉。
#
# COPYFILE_DISABLE=1 是必须的：不加的话 macOS 的 tar 会把扩展属性
# 写成 ._xxx 伴生文件，解出来塞满 app 包，重签还会失败。
if [ "${RELEASE:-0}" = "1" ] && [ -n "${STAGE_DIR:-}" ]; then
    ASSETS="$HERE/plugins/dsh-whalefloat-helper/assets"
    if [ -d "$(dirname "$ASSETS")" ]; then
        echo "▸ 打包插件内嵌安装包…"
        mkdir -p "$ASSETS"
        # 在 app 的父目录里打包，tar 里存的就是 WhaleFloat.app/ 这个相对前缀，
        # installer.js 正是按这个前缀解包后找 Contents/Info.plist。
        rm -f "$ASSETS/${APP_NAME}.app.tar.gz"
        ( cd "$(dirname "$DEST")" && COPYFILE_DISABLE=1 \
            tar -czf "$ASSETS/${APP_NAME}.app.tar.gz" "${APP_NAME}.app" )
        printf '%s' "$VERSION" > "$ASSETS/version.txt"
        SIZE="$(du -h "$ASSETS/${APP_NAME}.app.tar.gz" | cut -f1 | tr -d ' ')"
        echo "  内嵌安装包：${APP_NAME}.app.tar.gz（${SIZE}，版本 ${VERSION}）"
        # 打完立刻验一遍：解到临时目录看版本对不对、签名还在不在。
        # 这一步比事后靠用户报错便宜得多。
        PEEK="$(mktemp -d)"
        tar -xzf "$ASSETS/${APP_NAME}.app.tar.gz" -C "$PEEK"
        PEEK_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$PEEK/${APP_NAME}.app/Contents/Info.plist" 2>/dev/null || echo "读取失败")"
        if [ "$PEEK_VER" = "$VERSION" ] && codesign --verify --deep "$PEEK/${APP_NAME}.app" 2>/dev/null; then
            echo "  校验通过：解包版本 ${PEEK_VER}，签名有效"
        else
            echo "  ✗ 校验失败：解包版本 ${PEEK_VER}（期望 ${VERSION}），或签名无效"
            rm -rf "$PEEK"
            exit 1
        fi
        rm -rf "$PEEK"
    else
        echo "  ⚠ 找不到插件目录，跳过内嵌安装包"
    fi
fi
