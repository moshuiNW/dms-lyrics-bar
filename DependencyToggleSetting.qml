import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "../../Common/QmlUtils.js" as QmlUtils

/*
 * A ToggleSetting whose availability depends on an external binary.
 *
 * When the binary is missing the row is greyed out (DankToggle renders its own
 * M3 disabled state at 0.4 opacity), the description is replaced by install
 * instructions, and the stored value is forced off so the rest of the plugin
 * never acts on an unusable option.
 */
Row {
    id: root

    required property string settingKey
    required property string label
    // Human-readable name of the required binary, e.g. "OpenCC".
    required property string dependencyName
    required property var installHints   // array of strings, one per distro
    property string description: ""
    property bool defaultValue: false
    property bool value: defaultValue

    width: parent.width
    spacing: Theme.spacingM

    property bool isInitialized: false
    property bool dependencyAvailable: false

    // Detection runs once when the settings page is opened; it is cheap and
    // the page is recreated on each open, so re-entering picks up a newly
    // installed dependency without a shell restart.
    Process {
        id: dependencyProbe

        command: ["sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "sh",
                  root.dependencyName.toLowerCase()]
        running: true

        stdout: StdioCollector {}

        onExited: exitCode => {
            root.dependencyAvailable = exitCode === 0;
        }
    }

    function loadValue() {
        const settings = QmlUtils.findSettings(root.parent);
        if (settings && settings.pluginService) {
            const loadedValue = settings.loadValue(settingKey, defaultValue);
            value = loadedValue && dependencyAvailable;
            isInitialized = true;
        }
    }

    Component.onCompleted: Qt.callLater(loadValue)

    onDependencyAvailableChanged: {
        // Dependencies can only appear while the page is open after a manual
        // install; re-read so the toggle reflects reality.
        if (!dependencyAvailable && value)
            value = false;
    }

    onValueChanged: {
        if (!isInitialized)
            return;
        const settings = QmlUtils.findSettings(root.parent);
        if (settings)
            settings.saveValue(settingKey, value);
    }

    Column {
        width: parent.width - toggle.width - Theme.spacingM
        spacing: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter

        StyledText {
            text: root.label
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: root.dependencyAvailable ? Theme.surfaceText : Theme.surfaceVariantText
        }

        StyledText {
            text: root.dependencyAvailable
                ? root.description
                : qsTr("需要 %1（未安装）。安装后重新打开此页即可启用：%2")
                    .arg(root.dependencyName)
                    .arg(root.installHints.join("  ·  "))
            font.pixelSize: Theme.fontSizeSmall
            color: root.dependencyAvailable ? Theme.surfaceVariantText : Theme.error
            width: parent.width
            wrapMode: Text.WordWrap
            visible: text !== ""
        }
    }

    DankToggle {
        id: toggle

        anchors.verticalCenter: parent.verticalCenter
        enabled: root.dependencyAvailable
        checked: root.value
        onToggled: isChecked => {
            root.value = isChecked;
        }
    }
}
