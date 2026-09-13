#!/bin/bash
# 安装/更新「悬浮歌词」DMS 桌面插件
#
# 为什么装到 /etc/xdg 而不是 ~/.config：
#   本机 ~/.config 的权限是 drwx------（0700）。DMS 的 QML 引擎通过
#   file:// URL 解析插件路径时无法穿过这个目录，会报
#   "File name case mismatch"（这是个有误导性的报错，与大小写无关）。
#   系统插件目录 /etc/xdg/quickshell/dms-plugins 没有这个问题。
#   若要改回用户目录，需要放宽 ~/.config 权限，属于安全性降级，不推荐。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/etc/xdg/quickshell/dms-plugins/LyricsBar"

echo "==> 安装到 $DEST"
sudo mkdir -p "$DEST"
sudo cp "$SRC/plugin.json" "$SRC/LyricsBar.qml" "$SRC/LyricsBarDaemon.qml" \
      "$SRC/LyricsBarSettings.qml" "$SRC/DependencyToggleSetting.qml" \
      "$SRC/to-simplified.py" "$DEST/"
sudo chmod 644 "$DEST"/*.qml "$DEST"/plugin.json
sudo chmod 755 "$DEST"/to-simplified.py "$DEST"
sudo chmod 755 "$DEST"

echo "==> 检查可选依赖"
if ! command -v ffprobe >/dev/null 2>&1; then
    echo "    NOTE: ffprobe not found. Install ffmpeg to import embedded lyrics:"
    echo "          Fedora: sudo dnf install ffmpeg"
    echo "          Arch:   sudo pacman -S ffmpeg"
fi
if ! command -v opencc >/dev/null 2>&1; then
    echo "    NOTE: opencc not found (optional, for traditional -> simplified):"
    echo "          Fedora: sudo dnf install opencc-tools"
    echo "          Arch:   sudo pacman -S opencc"
    echo "          Debian: sudo apt install opencc"
fi

echo "==> 重启 DMS"
dms restart >/dev/null 2>&1 &
sleep 14

echo "==> 状态"
dms ipc call plugins list

cat <<'EOF'

注意：
  1. 设置入口不在「插件」页。DMS 对 type=desktop 的插件隐藏了那里的设置面板
     （PluginListItem.qml: showSettings = hasSettings && !isDesktopPlugin）。
     请到「设置 → 桌面组件」展开「悬浮歌词」改字号/透明度等。

  2. 拖动要用鼠标「右键」：DesktopPluginWrapper 的 dragArea/resizeArea
     只接受 acceptedButtons: Qt.RightButton。

  3. 拖动/缩放要求 clickThrough=false，因为 wrappper 里是
     enabled: !clickThrough —— 开启穿透会同时禁掉拖动和缩放。
     位置摆好后想让它穿透，再改回 true：
       dms ipc call desktopWidget setClickThrough dw_lyricsbar_main true
EOF
