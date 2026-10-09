// Содержимое карточки «О шелле» в хабе настроек. Пассивная: всё видно сразу, заходить никуда не нужно.
// Показывает версию, статус обновления (кнопка «Обновить до N» или «Всё ок, последняя версия»)
// и ссылки. Статус берётся из Updater (menu.updater), проверка идёт при каждом открытии настроек.
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../lang"

Item {
    id: ab
    required property var menu
    // true, если карточка сейчас в центре карусели (кнопки кликабельны только тогда)
    property bool current: false

    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary

    // ── ссылки: ПОМЕНЯЙ t.me-адреса на свои ─────────────────────────────
    readonly property var links: [
        { glyph: "\uf2c6", label: "about.tgChannel", url: "https://t.me/CHANGE_ME_channel" },
        { glyph: "\uf2c6", label: "about.tgMe",      url: "https://t.me/CHANGE_ME" },
        { glyph: "\uf09b", label: "about.git",       url: "https://github.com/22miligrams-cmyk/.Tech" }
    ]

    readonly property var upd: menu.updater
    readonly property string phase: upd ? upd.phase : "none"
    readonly property string localVer: upd && upd.localVersion ? upd.localVersion : "?"
    readonly property string remoteVer: upd && upd.remoteVersion ? upd.remoteVersion : "?"

    readonly property string versionText: phase === "available"
        ? Tr.fmt("about.verNew", [localVer, remoteVer])
        : Tr.fmt("about.ver", [localVer])

    readonly property string statusText: {
        if (phase === "available") return Tr.fmt("about.btnUpdate", [remoteVer])
        if (phase === "latest") return Tr.tr("about.btnOk")
        if (phase === "checking") return Tr.tr("about.btnChecking")
        if (phase === "error") return Tr.tr("about.btnError")
        return Tr.tr("about.btnCheck")
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 8

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "\uf05a"
            color: ab.colAccent
            font.pixelSize: 40
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: ".Tech"
            color: ab.colText
            font.pixelSize: 22
            font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: ab.versionText
            color: ab.phase === "available" ? ab.colAccent : ab.colText
            opacity: ab.phase === "available" ? 1.0 : 0.7
            font.pixelSize: 12
            font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }

        Item { Layout.fillHeight: true }

        // статус обновления: при новой версии это кнопка, при «всё ок» — спокойная плашка
        Rectangle {
            id: statusBox
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            radius: 10
            readonly property bool primary: ab.phase === "available"

            color: primary ? ab.colAccent
                : (ab.phase === "latest" ? Qt.alpha(ab.colAccent, 0.16) : Qt.alpha(ab.colText, 0.08))
            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: ab.statusText
                color: statusBox.primary ? ab.colBg : (ab.phase === "latest" ? ab.colAccent : ab.colText)
                font.pixelSize: 11
                font.bold: true
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }

            MouseArea {
                anchors.fill: parent
                enabled: ab.current
                cursorShape: Qt.PointingHandCursor
                onClicked: ab.menu.aboutAction()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: ab.links

                delegate: Rectangle {
                    id: chip
                    required property var modelData

                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: 9
                    color: Qt.alpha(ab.colText, chipMouse.containsMouse ? 0.18 : 0.08)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: chip.modelData.glyph
                            color: ab.colAccent
                            font.pixelSize: 13
                            font.family: "JetBrainsMono Nerd Font, Monospace"
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Tr.tr(chip.modelData.label)
                            color: ab.colText
                            font.pixelSize: 10
                            font.bold: true
                            font.family: "JetBrainsMono Nerd Font, Monospace"
                        }
                    }

                    MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        enabled: ab.current
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["xdg-open", chip.modelData.url])
                    }
                }
            }
        }
    }
}
