#!/bin/bash
# 安装/更新「悬浮歌词」DMS 桌面插件
#
# 为什么装到 /etc/xdg 而不是 ~/.config：
#   ~/.config 的权限通常是 drwx------（0700）。DMS 的 QML 引擎通过
#   file:// URL 解析插件路径时无法穿过这个目录，会报
#   "File name case mismatch"（这是个极具误导性的报错，与大小写无关）。
#   系统插件目录 /etc/xdg/quickshell/dms-plugins 没有这个问题。
#   若要改回用户目录，需放宽 ~/.config 权限，属于安全性降级，不推荐。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/etc/xdg/quickshell/dms-plugins/LyricsBar"

FILES=(
    plugin.json
    LyricsBar.qml
    LyricsBarDaemon.qml
    LyricsBarSettings.qml
    DependencyToggleSetting.qml
    to-simplified.py
)

for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC/$f" ]]; then
        echo "ERROR: 缺少文件 $SRC/$f" >&2
        exit 1
    fi
done

echo "==> 安装到 $DEST"
sudo mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    sudo cp "$SRC/$f" "$DEST/$f"
done
# QML 必须可读（不能是 0600，否则 DMS 进程读不到）
sudo chmod 644 "$DEST"/*.qml "$DEST"/plugin.json
sudo chmod 755 "$DEST"/to-simplified.py "$DEST"

echo "==> 检查可选依赖"
if ! command -v ffprobe >/dev/null 2>&1; then
    echo "    NOTE: 未找到 ffprobe。导入内嵌歌词需要 ffmpeg："
    echo "          Fedora: sudo dnf install ffmpeg"
    echo "          Arch:   sudo pacman -S ffmpeg"
fi
if ! command -v opencc >/dev/null 2>&1; then
    echo "    NOTE: 未找到 opencc（可选，用于繁体转简体）："
    echo "          Fedora: sudo dnf install opencc-tools"
    echo "          Arch:   sudo pacman -S opencc"
    echo "          Debian: sudo apt install opencc"
fi

# Quickshell 会缓存编译后的 QML（~/.cache/quickshell/qmlcache）。
# 不清缓存的话，改了 QML 也可能继续跑旧代码，极易误判为逻辑 bug。
echo "==> 清除 QML 编译缓存"
rm -rf "$HOME/.cache/quickshell/qmlcache" 2>/dev/null || true

echo "==> 重启 DMS"
dms kill >/dev/null 2>&1 || true
sleep 2
nohup dms run --session >/dev/null 2>&1 &
sleep 14

echo "==> 状态"
dms ipc call plugins list || true

cat <<'EOF'

注意
----
1. 设置入口不在「插件」页。DMS 对 type=desktop/composite 的插件隐藏了那里的
   设置面板（PluginListItem.qml: showSettings = hasSettings && !isDesktopPlugin）。
   请到「设置 → 桌面组件」展开「悬浮歌词」。

2. 拖动要用鼠标「右键」：DesktopPluginWrapper 的 dragArea/resizeArea
   只接受 acceptedButtons: Qt.RightButton。

3. 拖动/缩放要求 clickThrough=false，因为 wrapper 里是 enabled: !clickThrough
   —— 开启穿透会同时禁掉拖动和缩放。位置摆好后想让它穿透，再改回 true：
     dms ipc call desktopWidget setClickThrough dw_lyricsbar_main true

4. 改了 QML 但行为没变？先清缓存再重启：
     rm -rf ~/.cache/quickshell/qmlcache && dms restart

5. 插件内不要用相对路径 import（如 "../../Common/QmlUtils.js"）。
   那种写法只对 DMS 内部文件成立，插件里会解析失败，
   且失败是静默的——整个设置页会什么都不显示。详见 README「踩过的坑」第 13 条。
EOF
