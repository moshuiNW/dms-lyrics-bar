# DMS Lyrics Bar（悬浮歌词）

给 [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) 写的**桌面悬浮歌词条**，从**本地内嵌歌词**读取，通过 MPRIS 与播放器同步。本地没有时自动联网搜索。

为 niri 等 Wayland 合成器设计，独立于状态栏，位置可自由摆放。

> **本项目由 AI 完成**。全部代码、调试与文档均由 AI 编写。
> 详见文末[「关于本项目的来源」](#关于本项目的来源)。

---

## 特性

- **内嵌歌词优先，零网络请求** —— 从音乐文件的 `LYRICS` / `UNSYNCEDLYRICS` 标签提取 LRC，导入本地缓存后播放时直接命中，**不联网、不搜索、无等待**
- **在线兜底搜索** —— 本地找不到时自动到 lrclib.net 搜索同步歌词，搜到后写入本地缓存，下次秒开且离线可用
- **繁体转简体** —— 在线歌词经 OpenCC 自动转为简体（可选依赖，未安装时置灰并提示安装命令）
- **双行显示** —— 当前行加粗高亮，下一行暗色预告
- **封面取色** —— 歌词文字与进度条可从当前专辑封面提取主色
- **随播放器自动开关** —— 播放器启动时显示、退出时隐藏，无需手动操作
- **一键鼠标穿透** —— 锁定后点击穿透，不挡桌面操作，且不占用设置页

## 截图

```
┌──────────────────────────────────────────────┐
│ 🔓                                            │
│           泛黄的日记写永久                     │  ← 当前行（跟随封面取色）
│           讽刺我现在才会懂                     │  ← 下一行
│ ──────────────────────────────────────────── │  ← 进度条（同色）
└──────────────────────────────────────────────┘
```

## 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| DankMaterialShell | `>= 1.4.0` | 提供插件系统与桌面组件 |
| Quickshell | `>= 0.3` | DMS 的运行时 |
| niri / Hyprland | 任意 | 需要支持 `wlr-layer-shell`；其他合成器理论可用但未测试 |
| ffmpeg (`ffprobe`) | 任意 | **仅**导入内嵌歌词时需要 |
| **OpenCC** (`opencc`) | 任意 | **可选**；繁体转简体时需要，未安装时该选项置灰 |

在 Fedora 44 + DMS 1.6.1 + Quickshell 0.3.1 + niri 26.04 上开发验证。

## 安装

```bash
git clone https://github.com/moshuiNW/dms-lyrics-bar.git
cd dms-lyrics-bar
./install.sh
```

`install.sh` 会把插件装到 `/etc/xdg/quickshell/dms-plugins/LyricsBar` 并重启 DMS。

### 可选依赖：OpenCC

繁体转简体功能依赖 OpenCC（一个开源中文转换库）。**不装也能用**，只是在线歌词会保持原始繁体：

```bash
# Fedora
sudo dnf install opencc-tools

# Arch
sudo pacman -S opencc

# Debian / Ubuntu
sudo apt install opencc
```

安装后重新打开「设置 → 桌面组件 → 悬浮歌词」，该选项会从灰色变为可开关状态。

### ⚠️ 为什么装在 `/etc/xdg` 而不是 `~/.config`

这是个**必须知道**的坑。DMS 默认从 `~/.config/DankMaterialShell/plugins/` 读取用户插件，但如果该路径上的目录权限是 `0700`（多数发行版 `~/.config` 的默认值），QML 引擎通过 `file://` 解析插件路径时会失败，报出**极具误导性**的错误：

```
component error lyricsBar desktop ... LyricsBar.qml: File name case mismatch
```

这个报错**与大小写毫无关系**。实测把 DMS 自带的、确定能用的示例插件原样拷进该目录，**一样失败**——所以问题在路径权限，不在代码。

系统插件目录 `/etc/xdg/quickshell/dms-plugins` 没有这个问题。若想改回用户目录，需放宽 `~/.config` 权限（属于安全性降级，不推荐）。

## 使用

### 1. 导入内嵌歌词

```bash
# 默认扫描 ~/Music，也可指定目录或环境变量
python3 import-lyrics.py /path/to/your/music

# 环境变量方式
LYRICS_MUSIC_DIR=/path/to/music python3 import-lyrics.py

# 繁体转简体（需要 OpenCC，默认开启）
python3 import-lyrics.py /path/to/music

# 保留原始繁体
python3 import-lyrics.py /path/to/music --no-simplify

# 文件名是 "歌手 - 歌名" 而非默认的 "歌名 - 歌手"
python3 import-lyrics.py /path/to/music --artist-first

# 提供歌手提示（用于标签乱码的 WAV 文件）
echo '{"手写的从前": "周杰伦"}' > hints.json
python3 import-lyrics.py /path/to/music --artist-hints hints.json
```

歌词写入 `~/.cache/Lyrics/`，文件名与插件读取规则完全一致。

> 首次导入后即可**断网使用**（有内嵌歌词的歌曲）。

#### WAV 文件标签乱码处理

某些 WAV 文件（特别是用 Sound Forge 等工具标记的）存在两个问题：

1. **标签名非标准**：歌词写在 `LYRICS-XXX` 而非标准的 `LYRICS`。导入脚本通过前缀匹配兼容
2. **标签内容乱码**：ffprobe 返回的标题/歌手是 `U+FFFD` 替换字符，无法还原。脚本会：
   - 检测乱码并回退到文件名提取标题
   - 对于 `歌名 - 歌手.wav` 格式自动拆分
   - 对于无歌手信息的文件名（如 `手写的从前.wav`），用 `--artist-hints` 补充
   - 末尾报告仍有问题的文件，方便手动处理

### 2. 添加桌面组件

打开 **设置 → 桌面组件 → 添加组件 → Lyrics Bar（悬浮歌词）**。

> **注意**：设置入口**不在**「插件」页！DMS 对 `type: desktop/composite` 的插件有意隐藏了那里的设置面板：
> ```qml
> // PluginListItem.qml:35
> property bool showSettings: hasSettings && !isDesktopPlugin
> ```

### 3. 摆放与调整

| 操作 | 方式 |
|---|---|
| **移动位置** | 在歌词条上按住**鼠标右键**拖动 |
| **调整大小** | 右下角按住**鼠标右键**拖动 |
| **显示/隐藏锁按钮** | 鼠标移入歌词条 |
| **切换鼠标穿透** | 左键点击 🔓 / 🔒 |

> 拖动只认**右键**（DMS 的 `dragArea` 是 `acceptedButtons: Qt.RightButton`），左键无效。

## 设置项

设置路径：**设置 → 桌面组件 → 展开「悬浮歌词」**

### 显示

| 选项 | 默认 | 说明 |
|---|---|---|
| 播放器白名单 | `strawberry` | 留空则检测所有播放器 |
| 歌词字号 | 22 | 当前行字号 |
| 下一行字号差值 | -5 | 相对当前行缩小量 |
| 背景不透明度 | 45% | 0 为完全透明 |
| 🔒 休眠透明度 | 35% | 鼠标不在锁按钮上时的透明度，hover 时自动变亮 |
| 显示下一行 | 开 | |
| 显示播放进度条 | 关 | |
| 无歌词时显示歌名 | 开 | |
| 歌词颜色跟随封面 | 关 | 开启时会一并打开 DMS 的「媒体颜色跟随封面」 |
| 屏蔽词 | `作词, 作曲, 编曲, 制作人` | 命中则隐藏该行 |

### 随播放器

| 选项 | 默认 | 说明 |
|---|---|---|
| 随草莓音乐自动开关 | 开 | 播放器启动/退出时自动显示/隐藏歌词条 |
| 监听的播放器进程名 | `strawberry` | 可用空格分隔多个 |

### 在线歌词兜底

| 选项 | 默认 | 说明 |
|---|---|---|
| 启用在线歌词搜索 | 开 | 本地缓存未命中时到 lrclib.net 搜索 |
| 在线歌词转为简体 | 开 | **依赖 OpenCC**；未安装时置灰，描述显示安装命令 |
| 在线结果写入本地缓存 | 开 | 搜到的歌词存到 `~/.cache/Lyrics`，下次秒开 |
| 在线歌词时间偏移 | 0 | 整体提前或延后，每格 0.1 秒 |

## 架构

复合插件（`type: composite`），两个独立 surface：

```
LyricsBar/
├── plugin.json               # 清单：desktop + daemon 两个 surface
├── LyricsBar.qml             # 桌面组件：歌词渲染、MPRIS 同步、锁按钮
├── LyricsBarDaemon.qml       # 常驻守护：监听播放器进程，自动开关
├── LyricsBarSettings.qml     # 设置界面
├── DependencyToggleSetting.qml  # 依赖感知开关（未装依赖时置灰）
├── to-simplified.py          # 繁简转换辅助脚本（调用 OpenCC）
└── install.sh / import-lyrics.py
```

**歌词获取链路**：

```
MPRIS 元数据 (title/artist/album)
        ↓
  本地缓存 ~/.cache/Lyrics/<可读名>_<hash>.json
        ↓
  命中？── 是 ──→ 直接渲染（零网络）
        │
        否
        ↓
  curl lrclib.net/api/get ──→ 命中？── 是 ──→ to-simplified.py 转简体 ──→ 渲染 + 写缓存
        │                                                          │
        否                                                         ↓
        ↓                                               下次播放秒开、离线可用
  curl lrclib.net/api/search ──→ 取首个有同步歌词的结果
```

## 踩过的坑（供二次开发参考）

这些是实际调试中花了不少时间的点，记录下来避免重复踩：

### 1. `File name case mismatch` 其实是权限问题
见上文[安装章节](#️-为什么装在-etcxdg-而不是-config)。报错信息完全误导。

### 2. `screen` / `instanceId` 在构造后才注入
`DesktopPluginComponent` **不含** `screen` 属性，必须在插件里自行声明：

```qml
property var screen: null   // 基类没有，且 wrapper 仅在属性已存在时注入
```

因为 wrapper 是这么注入的：
```qml
if (item.screen !== undefined) item.screen = Qt.binding(() => root.screen);
```

且注入发生在 `contentLoader.onLoaded`，即**组件构造之后**。所以静态声明 `PanelWindow { screen: root.screen }` 会绑定到 `null` 且永不恢复——必须用 `Loader` 延迟创建。

### 3. `getScreenDisplayName` 属于 `SettingsData`，不是 `SessionData`
写错会抛 `TypeError`，位置查询静默返回 `null`。

### 4. 穿透与 hover 检测互斥
DMS 的 `clickThrough` 实现是**空输入遮罩**：
```qml
mask: root.clickThrough ? emptyMask : null
```
一旦穿透，整个窗口接收不到**任何**鼠标事件。因此：

- 锁按钮**不能**画在穿透区域内 → 否则锁上后无法解锁
- 覆盖全条的**独立 Overlay 窗口**会拦截右键 → 拖动失效
- 放在 **Bottom 层**虽不拦截，但被 Overlay 层的歌词条遮挡 → 收不到 hover

**最终方案**：
- **未锁定**：锁按钮画在歌词条内部，用 `MouseArea { acceptedButtons: Qt.NoButton }` 检测 hover（不接受任何按键，右键可穿透到 wrapper 的 dragArea）
- **已锁定**：由独立的 30×30 小窗口接管解锁，半透明常驻（因为穿透时无法检测 hover）

### 5. `StdioCollector` 读取用裸 `text`
是属性，不是函数。写成 `collector.text()` 会得到 `undefined`。

### 6. `Process.run()` 在 `command` 绑定重算期间调用会被静默丢弃
先赋值依赖属性，再用 `Qt.callLater` 置 `running = true`。

### 7. 定时重建歌词会导致闪烁
曾为「重新导入后自动生效」加了 5 秒轮询重建，结果每 5 秒歌词清空一次、回落到显示歌名，肉眼可见闪烁。改为**仅在未找到歌词时**轮询。

### 8. 播放位置双源打架
MPRIS 位置与本地插值同时生效会导致歌词行来回跳。应**优先信任 MPRIS**，仅在其不支持位置上报时才本地插值。

### 9. `Qt.btoa` / `TextEncoder` 在 Quickshell QML 运行时不可用
试图用 base64 编码 CJK payload 传递给 shell 会静默失败。改用 stdin 管道（`onStarted` 中 `write()` 然后 `stdinEnabled = false` 关闭 EOF）。

### 10. 桌面实例的 `pluginService` 是作用域受限的
`DesktopPluginWrapper` 为实例注入的不是全局 `PluginService`，而是一个只暴露 `loadPluginData` / `savePluginData` 的 `instanceScopedPluginService`——**不含** `getPluginPath`。要拿插件目录需从 `availablePlugins[id].pluginDirectory` 读。

### 11. WAV 标签乱码
ffprobe 对 WAV 的 RIFF INFO 块解码不可靠，返回的 CJK 标题常是 `U+FFFD` 替换字符，无法还原。用文件名回退 + 乱码检测（`U+FFFD` 或异常 Unicode 字符比例）解决。

### 12. lrclib 网络不稳定
同一请求在不同时刻返回 HTTP 200 或连接失败。加了 `--retry 3 --retry-connrefused`，且失败时不标记为「已尝试」，下次播放可重试。

## 兼容的播放器

理论上支持**所有正确实现 MPRIS2** 的播放器。开发时使用 **Strawberry**（草莓音乐）验证。

修改「播放器白名单」或「监听的播放器进程名」即可适配其他播放器（如 `yesplaymusic`、`mpv`、`elisa`）。

## 已知限制

- **内嵌歌词需为 LRC 格式**（带 `[mm:ss.xx]` 时间戳）。纯文本歌词无法同步
- **繁简转换依赖 OpenCC**：不装则在线歌词保持原始字形（可能是繁体）
- 锁定时 🔒 **半透明常驻**，无法做到「移开消失」：穿透与 hover 检测在技术上互斥（见[坑 4](#4-穿透与-hover-检测互斥)）
- 仅在 niri 上充分测试

## 卸载

```bash
sudo rm -rf /etc/xdg/quickshell/dms-plugins/LyricsBar
# 可选：清理歌词缓存与设置
rm -rf ~/.cache/Lyrics
```

---

## 关于本项目的来源

**本项目完全由 AI 编写。**

- **代码**：`LyricsBar.qml`、`LyricsBarDaemon.qml`、`LyricsBarSettings.qml`、`DependencyToggleSetting.qml`、`to-simplified.py`、`import-lyrics.py`、`install.sh`
- **调试**：全部问题定位（含上述 12 个坑）由 AI 完成
- **文档**：本 README 由 AI 撰写

人类提供的是**需求、方向与验收**：

1. 「草莓音乐有桌面歌词吗？可以配置我的 niri 使用的桌面歌词」
2. 顶栏太挤 → 改成独立悬浮条
3. 每次手动开关麻烦 → 随播放器自动开关
4. 颜色没跟随封面 → 修 bug
5. 加一个 🔒 鼠标穿透开关
6. 锁定后透明度要可调
7. 在线歌词搜索（仅本地没有时）
8. 繁体歌词要转简体，而且要做成可选依赖（没装就置灰提示）

以及在 AI 无法自行验证的环节（**鼠标悬停、点击、拖拽等真实交互**）进行人工测试与反馈。

使用的模型：DeepSeek（`deepseek-v4.1-flash`、`hy4-preview`）、GLM（`glm-5.2`、`glm-5.3`）与 Qwen（`qwen-token-plan-cn`），经 [DeepSeek Harness](https://github.com/deepseek-ai/dsh) 驱动。

## 许可

MIT
