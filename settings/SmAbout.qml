// Экран «О шелле» в настройках (четвёртая карточка хаба): версия, ссылки и кнопка обновления.
// Если на GitHub версия другая — кнопка «Обновить до N» запускает установщик в терминале.
// Если всё свежее — кнопка показывает «Всё ок, у тебя последняя версия».
// Статус берётся из Updater (menu.updater), а тихая проверка запускается при каждом открытии настроек.
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../lang"

Item {
    id: about
    required property var menu
    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary

    Layout.alignment: Qt.AlignHCenter
    Layout.preferredWidth: 560
    Layout.preferredHeight: 340

    // ── ссылки: ПОМЕНЯЙ t.me-адреса на свои ─────────────────────────────
    readonly property var links: [
        { glyph: "\uf2c6", label: "about.tgChannel", url: "https://t.me/HyprlandTech" },
        { glyph: "\uf2c6", label: "about.tgMe",      url: "https://t.me/K2dein" },
        { glyph: "\uf09b", label: "about.git",       url: "https://github.com/22miligrams-cmyk/.Tech" }
    ]

    readonly property var upd: menu.updater
    readonly property string phase: upd ? upd.phase : "none"
    readonly property string localVer: upd && upd.localVersion ? upd.localVersion : "?"
    readonly property string remoteVer: upd && upd.remoteVersion ? upd.remoteVersion : "?"

    readonly property string versionText: phase === "available"
        ? Tr.fmt("about.verNew", [localVer, remoteVer])
        : Tr.fmt("about.ver", [localVer])

    readonly property string btnText: {
        if (phase === "available") return Tr.fmt("about.btnUpdate", [remoteVer])
        if (phase === "latest") return Tr.tr("about.btnOk")
        if (phase === "checking") return Tr.tr("about.btnChecking")
        if (phase === "error") return Tr.tr("about.btnError")
        return Tr.tr("about.btnCheck")
    }

    // выбранный элемент: 0 — кнопка обновления, 1..N — ссылки
    property int sel: 0
    readonly property int count: 1 + links.length

    // действие по индексу
    function run(i) {
        if (i === 0) {
            if (!upd) return
            if (phase === "available") {
                upd.apply()
                menu.toggleMenu()          // меню закрываем, чтобы был виден терминал
            } else {
                upd.check(false, true)     // тихо перепроверить
            }
        } else {
            Quickshell.execDetached(["xdg-open", links[i - 1].url])
        }
    }

    onVisibleChanged: {
        if (visible) {
            sel = 0
            enterAnim.restart()
        }
    }

    Keys.onLeftPressed: sel = Math.max(0, sel - 1)
    Keys.onRightPressed: sel = Math.min(count - 1, sel + 1)
    Keys.onTabPressed: sel = (sel + 1) % count
    Keys.onUpPressed: sel = 0
    Keys.onDownPressed: if (sel === 0) sel = 1
    Keys.onReturnPressed: run(sel)
    Keys.onEnterPressed: run(sel)
    Keys.onEscapePressed: menu.goBack()

    Rectangle {
        id: card
        anchors.fill: parent
        radius: 14
        color: Qt.alpha(about.colSecondary, 0.9)

        ParallelAnimation {
            id: enterAnim
            NumberAnimation { target: card; property: "scale"; from: 0.9; to: 1.0; duration: 260; easing.type: Easing.OutCubic }
            NumberAnimation { target: card; property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutCubic }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 12

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12

                Text {
                    text: "\uf05a"
                    color: about.colAccent
                    font.pixelSize: 30
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }
                Text {
                    text: ".Tech"
                    color: about.colText
                    font.pixelSize: 26
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: about.versionText
                color: about.phase === "available" ? about.colAccent : about.colText
                opacity: about.phase === "available" ? 1.0 : 0.75
                font.pixelSize: 13
                font.bold: true
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: Tr.tr("about.desc")
                color: about.colText
                opacity: 0.55
                font.pixelSize: 11
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }

            Item { Layout.fillHeight: true }

            // ── кнопка обновления ──
            Rectangle {
                id: updBtn
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                radius: 12

                readonly property bool isSel: about.sel === 0
                readonly property bool primary: about.phase === "available"

                color: primary ? about.colAccent
                    : (about.phase === "latest" ? Qt.alpha(about.colAccent, isSel ? 0.28 : 0.16)
                                               : Qt.alpha(about.colText, isSel ? 0.16 : 0.08))
                border.width: isSel ? 2 : 0
                border.color: primary ? about.colText : about.colAccent
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 24
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: about.btnText
                    color: updBtn.primary ? about.colBg
                        : (about.phase === "latest" ? about.colAccent : about.colText)
                    font.pixelSize: 13
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: about.sel = 0
                    onClicked: about.run(0)
                }
            }

            // ── ссылки ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Repeater {
                    model: about.links

                    delegate: Rectangle {
                        id: linkBtn
                        required property var modelData
                        required property int index
                        readonly property bool isSel: about.sel === index + 1

                        Layout.fillWidth: true
                        Layout.preferredHeight: 38
                        radius: 10
                        color: Qt.alpha(about.colText, isSel ? 0.16 : 0.08)
                        border.width: isSel ? 2 : 0
                        border.color: about.colAccent
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Row {
                            anchors.centerIn: parent
                            spacing: 8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: linkBtn.modelData.glyph
                                color: about.colAccent
                                font.pixelSize: 15
                                font.family: "JetBrainsMono Nerd Font, Monospace"
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Tr.tr(linkBtn.modelData.label)
                                color: about.colText
                                font.pixelSize: 12
                                font.bold: true
                                font.family: "JetBrainsMono Nerd Font, Monospace"
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: about.sel = linkBtn.index + 1
                            onClicked: about.run(linkBtn.index + 1)
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: Tr.tr("about.hint")
                color: about.colText
                opacity: 0.45
                font.pixelSize: 9
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }
        }
    }
}
