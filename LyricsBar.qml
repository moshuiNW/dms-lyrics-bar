import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

/*
 * Floating desktop lyrics bar.
 *
 * Reads the exact cache layout LyricsEmbed writes
 * (~/.cache/Lyrics/<title> - <artist>_<fnv1a32>.json), so songs already
 * imported there render instantly with no network access and no re-parsing
 * of the audio files.
 *
 * Track metadata comes from DMS's MprisController; playback position is
 * polled because MPRIS position updates are not pushed by most players.
 */
DesktopPluginComponent {
    id: root

    minWidth: 260
    minHeight: 54

    // ── Plugin settings ────────────────────────────────────────────────
    // Desktop instances bind pluginData to instanceData.config, while the
    // settings page for non-instance surfaces writes to plugin_settings.json.
    // Read the instance config first, then fall back to the shared plugin
    // settings, so the options work no matter which path stored them.
    readonly property var sharedSettings: (typeof SettingsData !== "undefined")
        ? SettingsData.getPluginSettingsForPlugin("lyricsBar") : ({})

    function setting(key, fallback) {
        const local = pluginData ? pluginData[key] : undefined;
        if (local !== undefined && local !== null)
            return local;
        const shared = sharedSettings ? sharedSettings[key] : undefined;
        return (shared !== undefined && shared !== null) ? shared : fallback;
    }

    readonly property string playerWhitelist: setting("playerWhitelist", "strawberry")
    readonly property int fontSize: setting("fontSize", 22)
    readonly property int nextFontDelta: setting("nextFontDelta", -5)
    readonly property real bgOpacity: setting("backgroundOpacity", 45) / 100
    // Separate, user-tuned rest opacity for the lock button (0=hidden, 1=full).
    readonly property real lockRestOpacity: setting("lockOpacity", 35) / 100
    readonly property bool showNextLine: setting("showNextLine", true)
    readonly property bool showProgress: setting("showProgress", false)
    readonly property bool showTitleFallback: setting("showTitleFallback", true)
    readonly property bool colorByAlbum: setting("colorByAlbum", false)

    // Single source of truth for the "follow the cover" colour, shared by the
    // lyric text and the progress fill so they can never disagree.
    readonly property color accentColor: colorByAlbum ? MediaAccentService.accent : Theme.widgetTextColor
    // The progress fill falls back to the theme accent when the option is off,
    // matching how the bar looked before this was configurable.
    readonly property color progressFillColor: colorByAlbum ? MediaAccentService.accent : Theme.primary

    // Turning our option on implies turning DMS's extraction on, so the option
    // works on its own. The initial sync happens in the single
    // Component.onCompleted below (QML allows only one per object).
    onColorByAlbumChanged: {
        if (!colorByAlbum || typeof SettingsData === "undefined")
            return;
        if (!SettingsData.mediaUseAlbumArtAccent)
            SettingsData.set("mediaUseAlbumArtAccent", true);
    }
    readonly property string lyricBlocklist: setting("lyricBlocklist", "")
    readonly property bool bilingualJoin: setting("bilingualJoin", true)

    // Online fallback: only used when the local cache has no lyrics.
    readonly property bool onlineFallbackEnabled: setting("onlineFallbackEnabled", true)
    readonly property bool onlineCacheResults: setting("onlineCacheResults", true)
    // lrclib stores many Chinese songs in traditional characters; convert them
    // to simplified to match a typical local library.
    readonly property bool convertToSimplified: setting("convertToSimplified", true)
    // Extra seconds added to a fetched track's timing (some sources run early).
    readonly property real onlineOffset: setting("onlineOffset", 0) / 10

    // Helper shipped next to this component; converts the piped response.
    //
    // The desktop surface is handed an instance-scoped service that exposes
    // only loadPluginData/savePluginData -- no getPluginPath -- so the plugin
    // directory is read from availablePlugins instead. Falls back to `cat`
    // (a no-op) when conversion is disabled or the path cannot be resolved.
    readonly property string converterScript: {
        if (!root.convertToSimplified || !pluginService)
            return "/bin/cat";
        try {
            const all = pluginService.availablePlugins;
            const info = all ? all["lyricsBar"] : null;
            const dir = info ? info.pluginDirectory : "";
            return dir ? dir + "/to-simplified.py" : "/bin/cat";
        } catch (e) {
            return "/bin/cat";
        }
    }

    readonly property var blocklist: lyricBlocklist
        .split(",")
        .map(s => s.trim())
        .filter(s => s !== "")

    // ── Lock toggle ────────────────────────────────────────────────────
    // Where the lyrics bar sits, so the lock button can be placed on its
    // corner. Positions live in SessionData per instance + screen key.
    property var selfPosition: null

    function _refreshSelfPosition() {
        if (typeof SessionData === "undefined" || !selfInstanceId || !root.screen) {
            selfPosition = null;
            return;
        }
        const all = SessionData.desktopWidgetInstancePositions;
        const key = all ? all[selfInstanceId] : null;
        if (!key) {
            selfPosition = null;
            return;
        }
        // NOTE: getScreenDisplayName lives on SettingsData, not SessionData.
        const dn = SettingsData.getScreenDisplayName(root.screen);
        selfPosition = key[dn] ?? key["_synced"] ?? null;
    }

    readonly property real lockHostX: selfPosition?.x ?? 0
    readonly property real lockHostY: selfPosition?.y ?? 0
    // Declared here because DesktopPluginComponent does not define it, and the
    // wrapper only injects `screen` when the property already exists
    // (DesktopPluginWrapper: `if (item.screen !== undefined)`).
    property var screen: null

    readonly property string selfInstanceId: instanceId
    readonly property bool locked: {
        if (typeof SettingsData === "undefined" || !selfInstanceId)
            return false;
        const inst = (SettingsData.desktopWidgetInstances || [])
            .find(i => i.id === selfInstanceId);
        return inst?.config?.clickThrough === true;
    }

    function toggleLock() {
        if (!selfInstanceId || typeof SettingsData === "undefined")
            return;
        // This also disables drag/resize, since the wrapper gates both
        // MouseAreas on `enabled: !clickThrough`.
        SettingsData.updateDesktopWidgetInstanceConfig(selfInstanceId, {
            clickThrough: !locked
        });
    }

    // Hover state for the in-bar lock button (unlocked state only).
    // When locked, the bar is click-through and cannot report hover, so the
    // separate lock window below takes over and stays always-visible.
    property bool barHovered: false

    // Helper windows are created through a Loader because `screen` and
    // `instanceId` are injected AFTER construction.
    readonly property bool lockReady: root.screen !== null && root.screen !== undefined
        && root.selfInstanceId !== "" && root.selfPosition !== null

    // The in-bar lock button (unlocked state). Hover detection uses a
    // MouseArea INSIDE this widget with acceptedButtons: NoButton, so it
    // never intercepts the right-button drag the wrapper's dragArea needs.
    // Qt dispatches within one window: a MouseArea that does not accept a
    // button lets it fall through to lower items.
    readonly property bool inBarButtonVisible: !root.locked && root.barHovered

    Loader {
        id: lockedWindowLoader
        active: root.lockReady
        sourceComponent: lockedLockWindow
    }

    Component {
        id: lockedLockWindow

        // Separate small window shown ONLY while locked. The bar is
        // click-through then (empty input mask), so this is the only surface
        // that can receive the unlock click. It stays always-visible because
        // hover cannot be detected on a click-through bar.
        PanelWindow {
            screen: root.screen
            // Locked => always show the unlock button.
            visible: root.locked
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "dms:lyricsbar-lock"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors { left: true; top: true }

            WlrLayershell.margins {
                left: Math.max(0, root.lockHostX + 8)
                top: Math.max(0, root.lockHostY + 8)
            }

            implicitWidth: 30
            implicitHeight: 30

            Rectangle {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: lockedUnlockArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                // Tracks the bar's background opacity so the lock button stays
                // visually consistent with the card behind it; brightens on
                // hover so it reads as a tappable button.
                opacity: lockedUnlockArea.containsMouse ? Math.max(root.lockRestOpacity, 0.85) : root.lockRestOpacity
                border.width: 1
                border.color: Theme.outlineVariant
            }

            StyledText {
                anchors.centerIn: parent
                text: "🔒"
                font.pixelSize: 15
                font.family: "Noto Color Emoji, Segoe UI Emoji, sans-serif"
                color: Theme.surfaceText
                opacity: lockedUnlockArea.containsMouse ? 1.0 : Math.max(root.lockRestOpacity, 0.4)
            }

            MouseArea {
                id: lockedUnlockArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleLock()
            }
        }
    }

    // Hide-after-leave timer, shared by the in-bar hover area and button.
    Timer {
        id: hideTimer
        interval: 300
        repeat: false
        onTriggered: {
            // Only hide if the pointer has left BOTH the bar and the button.
            if (!inBarHover.containsMouse && !lockButtonArea.containsMouse)
                root.barHovered = false
        }
    }

    // ── Player selection ───────────────────────────────────────────────
    readonly property var matchedPlayers: {
        const all = MprisController.availablePlayers ?? [];
        const wanted = playerWhitelist.split(",").map(s => s.trim().toLowerCase()).filter(s => s !== "");
        if (wanted.length === 0)
            return all;
        return all.filter(p => {
            const identity = (p.identity || "").toLowerCase();
            const entry = (p.desktopEntry ? String(p.desktopEntry) : "").toLowerCase();
            return wanted.some(w => identity.includes(w) || entry.includes(w));
        });
    }

    // Prefer whichever matched player is actually playing.
    readonly property var player: {
        const list = matchedPlayers;
        if (!list || list.length === 0)
            return null;
        return list.find(p => p.isPlaying) ?? list[0];
    }

    readonly property string trackTitle: player?.trackTitle ?? ""
    readonly property string trackArtist: player?.trackArtist ?? ""
    readonly property string trackAlbum: player?.trackAlbum ?? ""
    readonly property real trackLength: (player && player.lengthSupported) ? player.length : 0

    // ── Playback clock ─────────────────────────────────────────────────
    // Polled rather than bound: MPRIS position changes are not signalled.
    property real position: 0
    property bool isPlaying: player?.isPlaying ?? false

    Timer {
        interval: 250
        running: root.player !== null && root.isPlaying
        repeat: true

        onTriggered: {
            const p = root.player;
            if (!p)
                return;
            // Always trust MPRIS when it supports position reporting. The old
            // `p.position > 0` guard made the very start of a track fall into
            // the local-increment branch, so the two sources fought and the
            // position jittered backwards, flipping the lyric line.
            if (p.positionSupported) {
                root.position = p.position;
                return;
            }
            // Only interpolate when the player cannot report a position.
            if (root.position < root.trackLength)
                root.position += 0.25;
        }
    }

    onPlayerChanged: root.position = 0

    // ── Lyrics loading ─────────────────────────────────────────────────
    property var lyricsLines: []
    property bool lyricsLoaded: false
    property string loadedKey: ""
    // Cache key of the lines currently shown; distinct from loadedKey, which
    // is set before the read starts.
    property string displayedKey: ""
    property string lyricsSource: ""
    // True once we have usable lines for the current track; gates the retry
    // timer so a loaded track is never re-read (which would flicker).
    readonly property bool lyricsFound: root.lyricsLines.length > 0

    // ── Online fallback ────────────────────────────────────────────────
    // Only consulted when the local cache has NO lyrics for the track, so a
    // library with embedded lyrics never touches the network.
    property bool onlineFetching: false
    property string onlineAttemptedKey: ""
    // Transient status shown in place of the next line while fetching.
    property string lyricStatus: ""

    readonly property string cacheDir: (Quickshell.env("HOME") || "") + "/.cache/Lyrics"

    function _fnv1a32(str) {
        var hash = 0x811c9dc5;
        for (var i = 0; i < str.length; i++)
            hash = Math.imul(hash ^ str.charCodeAt(i), 0x01000193) >>> 0;
        return ("00000000" + hash.toString(16)).slice(-8);
    }

    function _sanitize(name) {
        // Mirror Lyrics.qml: strip path-hostile characters.
        return String(name).replace(/[/\\:*?"<>|\x00-\x1f]/g, "_").replace(/^\.+|\.+$/g, "");
    }

    function _truncateUtf8(str, limit) {
        var bytes = 0;
        var out = "";
        for (var i = 0; i < str.length; i++) {
            var code = str.charCodeAt(i);
            var size = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0xd800 ? 3 : 2;
            if (bytes + size > limit)
                break;
            bytes += size;
            out += str[i];
        }
        return out;
    }

    function _cacheKey(title, artist) {
        return _fnv1a32((title + "\x00" + artist).toLowerCase());
    }

    function _cacheFile(title, artist) {
        const key = _cacheKey(title, artist);
        const readable = _truncateUtf8(_sanitize(title) + " - " + _sanitize(artist), 190);
        return cacheDir + "/" + readable + "_" + key + ".json";
    }

    // Legacy layout written by the upstream shell script.
    function _legacyCacheFile(title, artist) {
        return cacheDir + "/" + _cacheKey(title, artist) + ".json";
    }

    function _isBlocked(text) {
        if (root.blocklist.length === 0)
            return false;
        return root.blocklist.some(word => text.includes(word));
    }

    // ── LRC parsing (used for online results) ──────────────────────────
    // Same semantics as import-lyrics.py: lines without a timestamp inherit
    // the previous one, and duplicate (time, text) pairs are dropped.
    readonly property var _lrcStamp: /\[(\d+):(\d+(?:\.\d+)?)\]/g

    function _parseLrc(text) {
        if (!text)
            return [];
        const out = [];
        const rows = String(text).split(/\r?\n/);
        for (let i = 0; i < rows.length; i++) {
            const raw = rows[i].trim();
            if (raw === "")
                continue;
            // Collect every timestamp on the line (some sources emit several).
            const stamps = [];
            let m;
            root._lrcStamp.lastIndex = 0;
            while ((m = root._lrcStamp.exec(raw)) !== null)
                stamps.push(parseInt(m[1], 10) * 60 + parseFloat(m[2]));
            const content = raw.replace(/\[\d+:\d+(?:\.\d+)?\]/g, "").trim();
            if (content === "")
                continue;
            if (stamps.length > 0) {
                for (let s = 0; s < stamps.length; s++)
                    out.push({ time: Math.round(stamps[s] * 100) / 100, text: content });
            } else if (out.length > 0) {
                out.push({ time: out[out.length - 1].time, text: content });
            }
        }
        // De-duplicate, preserving order.
        const seen = ({});
        const unique = [];
        for (let i = 0; i < out.length; i++) {
            const k = out[i].time + "\u0000" + out[i].text;
            if (seen[k])
                continue;
            seen[k] = true;
            unique.push(out[i]);
        }
        return unique;
    }

    // ── Online fetch (fallback only) ───────────────────────────────────
    // Called exclusively when the local cache had nothing for this track.
    function _fetchOnlineLyrics(title, artist, album, duration) {
        if (!root.onlineFallbackEnabled || root.onlineFetching)
            return;
        const k = root._cacheKey(title, artist);
        if (root.onlineAttemptedKey === k)
            return;   // already tried for this exact track
        root.onlineAttemptedKey = k;
        root.onlineFetching = true;
        root.lyricStatus = "在线搜索中…";
        console.info("[LyricsBar] 本地无歌词，在线搜索: " + title + " - " + artist);

        // Build the exact-match query. encodeURIComponent keeps CJK intact.
        let url = "https://lrclib.net/api/get"
            + "?track_name=" + encodeURIComponent(title)
            + "&artist_name=" + encodeURIComponent(artist || "");
        if (album && album !== "")
            url += "&album_name=" + encodeURIComponent(album);
        if (duration > 0)
            url += "&duration=" + Math.round(duration);

        onlineFetcher.queryUrl = url;
        onlineFetcher.fallbackTitle = title;
        onlineFetcher.fallbackArtist = artist;
        onlineFetcher.queryDuration = duration;
        Qt.callLater(() => {
            if (root.loadedKey !== k)
                return;
            onlineFetcher.running = true;
        });
    }

    function _applyOnlinePayload(raw) {
        let data = null;
        try {
            data = JSON.parse(raw);
        } catch (e) {
            root.onlineFetching = false;
            root.lyricStatus = "在线搜索失败";
            return;
        }

        // /api/search returns an array; /api/get returns one object.
        let entry = null;
        if (Array.isArray(data)) {
            // Prefer a result that actually has synced lyrics.
            entry = data.find(x => x && x.syncedLyrics) ?? data[0] ?? null;
        } else {
            entry = data && data.syncedLyrics ? data : null;
        }

        root.onlineFetching = false;
        if (!entry || !entry.syncedLyrics) {
            // Nothing usable, and no plain fallback: leave the bar empty so the
            // title fallback shows.
            root.lyricStatus = "";
            root.onlineFetching = false;
            return;
        }

        const lines = root._parseLrc(entry.syncedLyrics)
            .filter(l => !root._isBlocked(String(l.text ?? "")));

        if (lines.length === 0) {
            root.lyricStatus = "";
            return;
        }

        // Guard: the track may have changed while the request was in flight.
        const wantKey = root._cacheKey(onlineFetcher.fallbackTitle, onlineFetcher.fallbackArtist);
        const nowKey = root._cacheKey(root.trackTitle, root.trackArtist);
        if (wantKey !== nowKey)
            return;   // track changed while the request was in flight

        console.info("[LyricsBar] 在线歌词已应用: " + root.trackTitle + " (" + lines.length + " 行)");

        const finalLines = root.onlineOffset !== 0
            ? lines.map(l => ({ time: Math.max(0, l.time + root.onlineOffset), text: l.text }))
            : lines;

        root.lyricsLines = finalLines;
        root.lyricsSource = "在线";
        root.displayedKey = wantKey;
        root.lyricsLoaded = true;
        root.lyricStatus = "";

        console.info("[LyricsBar] cacheResults=" + root.onlineCacheResults
            + " convert=" + root.convertToSimplified + " convScript=" + root.converterScript);
        if (root.onlineCacheResults)
            root._writeCache(onlineFetcher.fallbackTitle, onlineFetcher.fallbackArtist,
                             finalLines, entry.syncedLyrics);
    }

    // Persist a fetched result so subsequent plays are instant and offline.
    property string cacheWriterPath: ""
    property string cacheWriterPayload: ""

    function _writeCache(title, artist, lines, rawLrc) {
        // The payload is written over stdin rather than passed as an argument:
        // it contains CJK text and newlines, which do not survive shell
        // argument quoting. Qt.btoa/TextEncoder are not available in this QML
        // runtime, so no client-side encoding is attempted.
        cacheWriter.finalPath = root._cacheFile(title, artist);
        cacheWriter.payload = JSON.stringify({
            lines: lines,
            source: 5,   // 5 = online (lrclib), matching our own convention
            cachedAt: new Date().toISOString(),
            offset: 0
        });
        Qt.callLater(() => { cacheWriter.running = true; });
    }

    function reloadLyrics() {
        const title = root.trackTitle;
        const artist = root.trackArtist;
        if (!title) {
            root.lyricsLines = [];
            root.lyricsLoaded = false;
            root.loadedKey = "";
            return;
        }

        const key = root._cacheKey(title, artist);
        if (key === root.loadedKey && root.lyricsLoaded)
            return;

        root.loadedKey = key;
        // Only clear on an actual track change. Keeping the previous lines
        // visible while re-reading the same track avoids a blank frame.
        if (root.displayedKey !== key) {
            root.lyricsLines = [];
            root.lyricsSource = "";
        }
        root.lyricsLoaded = false;

        // Assign both inputs, then start on the next tick so the `command`
        // binding has recomputed before the process is launched.
        cacheReader.running = false;
        cacheReader.wantedTitle = title;
        cacheReader.wantedArtist = artist;
        Qt.callLater(() => {
            if (root.loadedKey !== key)
                return;
            cacheReader.running = true;
        });
    }

    onTrackTitleChanged: {
        root.position = 0;
        reloadLyrics();
    }
    onTrackArtistChanged: reloadLyrics()
    Component.onCompleted: {
        reloadLyrics();
        // Ensure the cover-colour pipeline is on if the user already opted in.
        if (colorByAlbum && typeof SettingsData !== "undefined" && !SettingsData.mediaUseAlbumArtAccent)
            SettingsData.set("mediaUseAlbumArtAccent", true);
    }

    // `screen` and `instanceId` are injected after construction, so the bar
    // position cannot be read once at startup. Poll it; this also tracks the
    // widget being dragged, keeping the lock button on its corner.
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root._refreshSelfPosition()
    }

    // Reads the canonical cache file, falling back to the legacy hash-only
    // name. `text` is the StdioCollector property, not a function.
    //
    // Note: `command` is bound to the two `wanted*` properties, so assigning
    // both and then setting `running` gives the binding a settled value before
    // the process starts. Calling run() while the command is still being
    // recomputed silently drops the execution.
    Process {
        id: cacheReader

        property string wantedTitle: ""
        property string wantedArtist: ""

        command: {
            const primary = root._cacheFile(wantedTitle, wantedArtist);
            const legacy = root._legacyCacheFile(wantedTitle, wantedArtist);
            const script = "if [ -f \"$1\" ]; then cat \"$1\"; elif [ -f \"$2\" ]; then cat \"$2\"; fi";
            return ["bash", "-c", script, "bash", primary, legacy];
        }

        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (text || "").trim();
                if (raw === "") {
                    // Nothing cached locally. This is the ONLY path that may
                    // go online, so a library with embedded lyrics stays
                    // entirely offline.
                    root.lyricsLines = [];
                    root.lyricsSource = "";
                    root.displayedKey = root._cacheKey(cacheReader.wantedTitle, cacheReader.wantedArtist);
                    root.lyricsLoaded = true;
                    root._fetchOnlineLyrics(cacheReader.wantedTitle,
                                            cacheReader.wantedArtist,
                                            root.trackAlbum,
                                            root.trackLength);
                    return;
                }
                try {
                    const data = JSON.parse(raw);
                    const lines = (data.lines ?? []).filter(l => !root._isBlocked(String(l.text ?? "")));
                    // Guard against a stale read after the track changed.
                    if (cacheReader.wantedTitle !== root.trackTitle
                            || cacheReader.wantedArtist !== root.trackArtist)
                        return;
                    root.lyricsLines = lines;
                    root.lyricsSource = "内嵌";
                    root.displayedKey = root._cacheKey(cacheReader.wantedTitle, cacheReader.wantedArtist);
                    root.lyricsLoaded = true;
                } catch (e) {
                    console.warn("[LyricsBar] 解析缓存失败:", e);
                    root.lyricsLines = [];
                    root.displayedKey = root._cacheKey(cacheReader.wantedTitle, cacheReader.wantedArtist);
                    root.lyricsLoaded = true;
                }
            }
        }
    }

    // Online lookup against lrclib.net (free, no API key, returns synced LRC).
    // Reached only from the cache-miss branch above.
    Process {
        id: onlineFetcher

        property string queryUrl: ""
        property string fallbackTitle: ""
        property string fallbackArtist: ""
        property real queryDuration: 0
        property bool triedSearch: false

        // --retry handles transient DNS/TLS/connection failures, which were
        // observed in practice: the same request alternates between HTTP 200
        // and a hard connection error, and a naive one-shot curl would look
        // like "no lyrics available" for a song that is actually indexed.
        // lrclib indexes many Chinese songs in traditional characters while
        // local libraries are usually tagged in simplified, so the response is
        // piped through a converter. The helper fails open (passes data
        // through untouched) when OpenCC is not installed.
        command: ["bash", "-c",
                  "curl -sL --max-time 12 --retry 3 --retry-delay 1 --retry-connrefused "
                  + "-H 'User-Agent: dms-lyrics-bar (https://github.com/moshuiNW/dms-lyrics-bar)' "
                  + "\"$1\" | python3 \"$2\"",
                  "bash", queryUrl, root.converterScript]

        running: false

        onExited: exitCode => {
            if (exitCode !== 0)
                console.warn("[LyricsBar] 在线请求退出码:", exitCode, "url=" + queryUrl
                    + " converter=" + root.converterScript);
        }

        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (text || "").trim();
                console.info("[LyricsBar] 在线响应 " + raw.length + " 字节: " + raw.slice(0, 120));
                let ok = false;
                try {
                    const parsed = JSON.parse(raw);
                    ok = Array.isArray(parsed) ? parsed.length > 0
                                               : !!(parsed && parsed.syncedLyrics);
                } catch (e) {
                    ok = false;
                }

                // Exact match failed -> retry once with the fuzzy search
                // endpoint before giving up on this track.
                if (!ok && !onlineFetcher.triedSearch) {
                    onlineFetcher.triedSearch = true;
                    const q = onlineFetcher.fallbackTitle
                        + (onlineFetcher.fallbackArtist ? " " + onlineFetcher.fallbackArtist : "");
                    onlineFetcher.queryUrl = "https://lrclib.net/api/search?q=" + encodeURIComponent(q);
                    onlineFetcher.running = false;
                    Qt.callLater(() => { onlineFetcher.running = true; });
                    return;
                }

                onlineFetcher.triedSearch = false;
                root._applyOnlinePayload(raw);

                // A request that produced nothing usable leaves the field open
                // so a later play can try again; a definitive "not found" from
                // a successful request is remembered to avoid hammering the API.
                if (!ok) {
                    root.onlineAttemptedKey = "";
                    root.onlineFetching = false;
                    root.lyricStatus = "";
                }
            }
        }
    }

    // Writes a fetched result into ~/.cache/Lyrics so later plays are instant
    // and work offline. Payload arrives base64-encoded via the environment.
    Process {
        id: cacheWriter

        property string finalPath: ""
        property string payload: ""

        // Write to a temp file then rename, so a partially written cache entry
        // can never be read. `cat` reads the payload from stdin.
        command: ["bash", "-c",
                  "cat > \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\"",
                  "bash", finalPath]

        stdinEnabled: true
        running: false

        // Writing must happen once the process is up; closing stdin afterwards
        // lets `cat` see EOF so the rename runs.
        onStarted: {
            cacheWriter.write(cacheWriter.payload);
            cacheWriter.stdinEnabled = false;
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const e = (text || "").trim();
                if (e !== "")
                    console.warn("[LyricsBar] 写入缓存失败:", e);
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                console.warn("[LyricsBar] 缓存写入退出码:", exitCode);
        }
    }

    // Retry only while we have no lyrics yet for the current track (e.g. the
    // cache was written after playback started). Once found, stop polling:
    // reloadLyrics() blanks the lines for a few frames while the file is read,
    // which shows up as a periodic flicker back to the song title.
    Timer {
        interval: 5000
        running: root.trackTitle !== "" && !root.lyricsFound
        repeat: true

        onTriggered: root.reloadLyrics()
    }

    // ── Current line lookup ────────────────────────────────────────────
    readonly property int currentIndex: {
        const lines = root.lyricsLines;
        if (!lines || lines.length === 0)
            return -1;
        const pos = root.position;
        // Binary search for the last line whose timestamp has passed.
        var lo = 0;
        var hi = lines.length - 1;
        var found = -1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            if ((lines[mid].time ?? 0) <= pos) {
                found = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        return found;
    }

    readonly property string currentText: {
        const i = root.currentIndex;
        if (i < 0 || i >= root.lyricsLines.length)
            return "";
        return (root.lyricsLines[i].text ?? "").trim();
    }

    readonly property string nextText: {
        const i = root.currentIndex;
        if (i < 0)
            return root.lyricsLines.length > 0 ? (root.lyricsLines[0].text ?? "").trim() : "";
        if (i + 1 >= root.lyricsLines.length)
            return "";
        return (root.lyricsLines[i + 1].text ?? "").trim();
    }

    readonly property string headline: {
        if (root.lyricsLines.length === 0) {
            if (!root.showTitleFallback)
                return "";
            if (!root.trackTitle)
                return root.player ? "" : "未检测到播放器";
            return root.trackArtist ? root.trackTitle + " - " + root.trackArtist : root.trackTitle;
        }
        return root.currentText;
    }

    // ── Rendering ──────────────────────────────────────────────────────
    Rectangle {
        id: card

        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        opacity: root.bgOpacity
    }

    Column {
        id: content

        anchors.fill: parent
        anchors.margins: Theme.spacingS
        spacing: 2

        StyledText {
            id: mainLine

            width: parent.width
            text: root.headline
            font.pixelSize: root.fontSize
            font.weight: Font.Bold
            font.family: Theme.fontFamily
            color: root.accentColor
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.NoWrap
            maximumLineCount: 1
            elide: Text.ElideRight
            visible: text !== ""
        }

        StyledText {
            id: nextLine

            width: parent.width
            // While an online lookup is in flight, show that instead of the
            // (empty) next line, so the wait is visible rather than silent.
            text: root.lyricStatus !== ""
                ? root.lyricStatus
                : (root.showNextLine ? root.nextText : "")
            font.pixelSize: Math.max(10, root.fontSize + root.nextFontDelta)
            font.family: Theme.fontFamily
            color: Theme.surfaceText
            opacity: 0.65
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.NoWrap
            maximumLineCount: 1
            elide: Text.ElideRight
            visible: text !== ""
        }
    }

    Rectangle {
        id: progressTrack

        visible: root.showProgress && root.trackLength > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spacingS
        height: 2
        radius: 1
        color: Theme.surfaceContainerHighest

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, root.position / Math.max(1, root.trackLength)))
            height: parent.height
            radius: parent.radius
            // Same source as the lyric text so the bar follows the cover art
            // when that option is on. The "next line" text deliberately keeps
            // its theme colour.
            color: root.progressFillColor
        }
    }

    // ── In-bar hover detection + lock button (unlocked state) ────────
    // Hover is detected HERE, inside the bar's own window, not on a separate
    // surface. A separate Overlay window would intercept right-clicks the
    // wrapper's dragArea needs; a Bottom one is occluded and never sees hover.
    // acceptedButtons: NoButton means this MouseArea never steals clicks,
    // so right-drag still reaches dragArea (Qt passes unaccepted buttons
    // through to lower items in the same window).
    MouseArea {
        id: inBarHover

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        z: 99
        onEntered: {
            hideTimer.stop();
            root.barHovered = true;
        }
        onExited: hideTimer.restart()
    }

    // The lock button itself, drawn at the bar's top-left corner. Only shown
    // while unlocked + hovered. While locked the bar is click-through (empty
    // mask), so this becomes unreachable; the separate lockedLockWindow
    // handles unlock then.
    Item {
        id: inBarLockButton

        x: 8
        y: 8
        width: 30
        height: 30
        visible: root.inBarButtonVisible

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: lockButtonArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
            // Same opacity source as the locked-state button: follows the
            // bar's background opacity, brightens on hover.
            opacity: lockButtonArea.containsMouse ? Math.max(root.lockRestOpacity, 0.85) : root.lockRestOpacity
            border.width: 1
            border.color: Theme.outlineVariant
        }

        StyledText {
            anchors.centerIn: parent
            text: "🔓"
            font.pixelSize: 15
            font.family: "Noto Color Emoji, Segoe UI Emoji, sans-serif"
            color: Theme.surfaceText
            opacity: lockButtonArea.containsMouse ? 1.0 : Math.max(root.lockRestOpacity, 0.4)
        }

        MouseArea {
            id: lockButtonArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleLock()
            onEntered: hideTimer.stop()
            onExited: hideTimer.restart()
        }
    }
}
