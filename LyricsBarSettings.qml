import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "lyricsBar"

    StyledText {
        width: parent.width
        text: "悬浮歌词设置"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "独立悬浮歌词条，读取本地内嵌 LRC。位置与大小在「桌面组件」页拖动调整。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "playerWhitelist"
        label: "播放器白名单"
        description: "留空则检测所有播放器；填 strawberry 只跟随草莓音乐"
        placeholder: "strawberry"
        defaultValue: "strawberry"
    }

    SliderSetting {
        settingKey: "fontSize"
        label: "歌词字号"
        description: "当前行的字号，下一行按下方差值自动缩小"
        defaultValue: 22
        minimum: 12
        maximum: 48
        unit: "px"
    }

    SliderSetting {
        settingKey: "nextFontDelta"
        label: "下一行字号差值"
        description: "相对当前行的缩小量，负数比当前行小"
        defaultValue: -5
        minimum: -14
        maximum: 0
        unit: "px"
    }

    SliderSetting {
        settingKey: "backgroundOpacity"
        label: "背景不透明度"
        description: "0 为完全透明，只显示文字"
        defaultValue: 45
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "lockOpacity"
        label: "🔒 休眠透明度"
        description: "鼠标不在锁按钮上时的透明度；hover 时自动变亮。0=完全隐藏，100=全不透"
        defaultValue: 35
        minimum: 0
        maximum: 100
        unit: "%"
    }

    ToggleSetting {
        settingKey: "showNextLine"
        label: "显示下一行"
        description: "在下方预告下一句歌词"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showProgress"
        label: "显示播放进度条"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showTitleFallback"
        label: "无歌词时显示歌名"
        description: "关闭后找不到歌词就留空"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "colorByAlbum"
        label: "歌词颜色跟随封面"
        description: "从当前专辑封面取主色作为歌词颜色；开启时会一并打开 DMS 的『媒体颜色跟随封面』"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "autoShowWithPlayer"
        label: "随草莓音乐自动开关"
        description: "草莓音乐启动时显示悬浮歌词，退出时自动隐藏，无需手动到桌面组件里开关"
        defaultValue: true
    }

    StringSetting {
        settingKey: "watchedProcess"
        label: "监听的播放器进程名"
        description: "随上面开关生效。留空默认 strawberry；可用空格分隔多个，如 strawberry yesplaymusic"
        placeholder: "strawberry"
        defaultValue: "strawberry"
    }

    StringSetting {
        settingKey: "lyricBlocklist"
        label: "屏蔽词"
        description: "歌词行包含任一关键词则不显示，多个用逗号分隔"
        placeholder: "作词, 作曲, 编曲, 制作人"
        defaultValue: "作词, 作曲, 編曲, 编曲, 制作人"
    }

    StyledText {
        width: parent.width
        text: "在线歌词兜底"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "仅当本地找不到内嵌歌词时才会联网搜索；曲库都有内嵌歌词时完全不联网。数据源：lrclib.net（免费、无需密钥）"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "onlineFallbackEnabled"
        label: "启用在线歌词搜索"
        description: "本地缓存未命中时，自动到 lrclib.net 搜索同步歌词"
        defaultValue: true
    }

    // Greyed out until OpenCC is installed; the description then shows the
    // per-distro install commands instead of the normal hint.
    DependencyToggleSetting {
        settingKey: "convertToSimplified"
        label: "在线歌词转为简体"
        description: "lrclib 的中文歌词多为繁体，开启后经 OpenCC 转为简体"
        dependencyName: "OpenCC"
        installHints: [
            "Fedora: sudo dnf install opencc-tools",
            "Arch: sudo pacman -S opencc",
            "Debian: sudo apt install opencc"
        ]
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "onlineCacheResults"
        label: "在线结果写入本地缓存"
        description: "把搜到的歌词存到 ~/.cache/Lyrics，之后播放同一首歌秒开且无需联网"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "onlineOffset"
        label: "在线歌词时间偏移"
        description: "在线歌词整体提前或延后。每格 0.1 秒，负值提前、正值延后"
        defaultValue: 0
        minimum: -50
        maximum: 50
        unit: "×0.1s"
    }
}
