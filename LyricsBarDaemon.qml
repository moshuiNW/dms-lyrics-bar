import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services

/*
 * Process watcher for the floating lyrics bar.
 *
 * Strawberry is the only player this bar follows, and the desktop widget is
 * pointless (and visually intrusive) when it is not running. This daemon polls
 * for the player process and toggles the widget instance's `enabled` flag, so
 * the lyrics appear and disappear together with Strawberry.
 *
 * Polling rather than a D-Bus name watch on purpose: Strawberry keeps its
 * MPRIS name alive briefly across restarts, and org.freedesktop.DBus
 * NameOwnerChanged would not reliably distinguish "closed" from "restarting".
 */
Item {
    id: root

    property var pluginService: null
    property string pluginId: "lyricsBar"

    // Instance registered in settings.json / session.json.
    readonly property string widgetInstanceId: "dw_lyricsbar_main"

    // Read from the instance config first (that is where the desktop widget's
    // settings page writes), then fall back to the shared plugin settings.
    property var sharedSettings: ({})
    property var instanceConfig: ({})

    function _refreshSettings() {
        if (typeof SettingsData === "undefined")
            return;
        sharedSettings = SettingsData.getPluginSettingsForPlugin(pluginId) || ({});
        const inst = (SettingsData.desktopWidgetInstances || [])
            .find(i => i.id === root.widgetInstanceId);
        instanceConfig = inst?.config ?? ({});
    }

    function _setting(key, fallback) {
        const local = instanceConfig ? instanceConfig[key] : undefined;
        if (local !== undefined && local !== null)
            return local;
        const shared = sharedSettings ? sharedSettings[key] : undefined;
        return (shared !== undefined && shared !== null) ? shared : fallback;
    }

    readonly property bool autoShow: _setting("autoShowWithPlayer", true)

    // Lower-case process names that count as "the music player is running".
    readonly property var watchedProcesses: {
        const raw = String(_setting("watchedProcess", "strawberry")).trim();
        const list = raw.split(/[\s,]+/).filter(s => s !== "");
        return list.length > 0 ? list : ["strawberry"];
    }

    // Consecutive detections required before flipping state, so a momentary
    // gap during a track change cannot make the widget blink out.
    readonly property int confirmTicks: 2

    property bool playerRunning: false
    property int _hits: 0
    property int _misses: 0
    property bool _initialised: false

    function _setWidgetEnabled(enabled) {
        if (typeof SettingsData === "undefined")
            return;
        const instances = SettingsData.desktopWidgetInstances || [];
        const inst = instances.find(i => i.id === root.widgetInstanceId);
        if (!inst)
            return;
        if (!!inst.enabled === !!enabled)
            return;
        SettingsData.updateDesktopWidgetInstance(root.widgetInstanceId, { enabled: !!enabled });
        console.info("[LyricsBar/daemon] 草莓音乐" + (enabled ? "启动" : "关闭")
                     + " → 悬浮歌词" + (enabled ? "显示" : "隐藏"));
    }

    // `pgrep -x` matches the exact executable name, avoiding false positives
    // from paths or window titles that merely contain "strawberry".
    Process {
        id: probe

        command: {
            const names = root.watchedProcesses.map(n => "\"" + n + "\"").join(" ");
            return ["bash", "-c", "pgrep -x " + names + " >/dev/null 2>&1 && echo yes || echo no"];
        }

        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const running = (text || "").trim() === "yes";
                if (running) {
                    root._misses = 0;
                    root._hits += 1;
                } else {
                    root._hits = 0;
                    root._misses += 1;
                }

                const ticks = root.confirmTicks;
                if (!root.autoShow) {
                    // Feature off: just track the state, never touch the widget.
                    root._initialised = true;
                    root.playerRunning = running;
                    return;
                }
                if (!root._initialised) {
                    // First probe decides the initial state immediately, so the
                    // widget matches reality right after a shell restart.
                    root._initialised = true;
                    root.playerRunning = running;
                    root._setWidgetEnabled(running);
                    return;
                }
                if (!root.playerRunning && root._hits >= ticks) {
                    root.playerRunning = true;
                    root._setWidgetEnabled(true);
                } else if (root.playerRunning && root._misses >= ticks) {
                    root.playerRunning = false;
                    root._setWidgetEnabled(false);
                }
            }
        }
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            // Re-read settings each tick so option changes apply without a
            // shell restart, and pick up the injected pluginService.
            root._refreshSettings();
            if (!probe.running)
                probe.running = true;
        }
    }

    // If the user turns the auto-show option off while the widget is hidden by
    // us, put it back so the widget is never left in a state the user did not
    // choose. Turning it on re-syncs to the current process state on next tick.
    onAutoShowChanged: {
        if (autoShow)
            return;
        root._setWidgetEnabled(true);
    }
}
