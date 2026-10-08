import QtQuick

Item {
    id: kl

    property string text: ""
    property var words: []
    property int wordIndex: -1
    property bool wrap: false
    property bool jumpEnabled: true

    property color color: "white"
    property color dotColor: "white"
    property int pixelSize: 12
    property bool bold: false
    property string family: "JetBrainsMono Nerd Font, Monospace"

    readonly property real dotSize: wrap ? 6 : 4
    readonly property real reserve: wrap ? 14 : 10
    readonly property real minArc: wrap ? 4 : 1.5
    readonly property real maxArc: wrap ? 14 : 3.5
    readonly property real contentW: te.contentWidth
    implicitHeight: reserve + te.contentHeight

    property real fromX: 0
    property real fromY: 0
    property real toX: 0
    property real toY: 0
    property real jt: 1
    property real arc: 0
    property real landSq: 0
    readonly property real dotX: fromX + (toX - fromX) * jt
    readonly property real dotYpos: fromY + (toY - fromY) * jt - arc * 4 * jt * (1 - jt)
    readonly property real sq: (jt < 1 ? 0.5 * Math.sin(Math.PI * jt) : 0) + landSq

    property bool showDot: false
    property real scrollX: 0
    property bool snapping: false
    property string lastLine: "\u0000"
    property int lastIdx: -1

    // Timer вместо Qt.callLater: таймер умирает вместе с элементом, поэтому отложенный вызов
    // не прилетит в уже удалённую строку списка (из-за этого quickshell падал)
    Timer { id: updT; interval: 0; onTriggered: kl.updateDot() }
    Timer { id: unsnapT; interval: 0; onTriggered: kl.unsnap() }

    function schedule() { updT.restart() }
    function unsnap() { kl.snapping = false }

    function jumpTo(x, y, animate) {
        if (!animate) {
            jumpAnim.stop()
            fromX = x; fromY = y; toX = x; toY = y
            jt = 1
            landSq = 0
            return
        }
        const cx = kl.dotX, cy = fromY + (toY - fromY) * jt
        const dx = x - cx, dy = y - cy
        const dist = Math.sqrt(dx * dx + dy * dy)
        jumpAnim.stop()
        landSq = 0
        fromX = cx; fromY = cy; toX = x; toY = y
        arc = Math.min(maxArc, minArc + dist * 0.05)
        flight.duration = (wrap ? 200 : 150) + Math.min(dist, 240) * 0.4
        jt = 0
        jumpAnim.start()
    }


    function updateDot() {
        if (te.text !== lastLine) {
            lastLine = te.text
            snapping = true
            scrollX = 0
            lastIdx = -1
            unsnapT.restart()
        }

        const W = kl.words
        const i = kl.wordIndex
        const ok = W && W.length > 0 && W[0].line === te.text && i >= 0 && i < W.length
        if (!ok) {
            showDot = false
            lastIdx = -1
            return
        }

        const w = W[i]
        const r0 = te.positionToRectangle(w.s)
        const r1 = te.positionToRectangle(w.e)
        const sameLine = Math.abs(r1.y - r0.y) < 1
        const cx = sameLine ? (r0.x + r1.x) / 2 : r0.x + 4
        const cy = te.y + r0.y - dotSize - 1.5

        if (!showDot || lastIdx === -1) {
            jumpTo(cx, cy, false)
        } else if (lastIdx !== i) {
            jumpTo(cx, cy, jumpEnabled && (w.b - w.a) >= 0.22)
        } else if (!jumpAnim.running) {
            jumpTo(cx, cy, false)
        }
        showDot = true
        lastIdx = i

        if (!wrap) {
            const vw = kl.width, cw = te.contentWidth
            if (cw <= vw) {
                scrollX = 0
            } else {
                const sx = cx + scrollX
                if (sx > vw * 0.75 || sx < vw * 0.08)
                    scrollX = Math.max(vw - cw, Math.min(0, vw * 0.25 - cx))
            }
        }
    }

    onWordsChanged: schedule()
    onWordIndexChanged: schedule()
    onWrapChanged: schedule()
    onWidthChanged: schedule()
    Component.onCompleted: schedule()


    Behavior on scrollX { enabled: !kl.snapping; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    SequentialAnimation {
        id: jumpAnim
        NumberAnimation { id: flight; target: kl; property: "jt"; from: 0; to: 1; duration: 260; easing.type: Easing.InOutSine }

        NumberAnimation { target: kl; property: "landSq"; to: -0.7; duration: kl.wrap ? 55 : 0; easing.type: Easing.OutQuad }
        NumberAnimation { target: kl; property: "landSq"; to: 0; duration: kl.wrap ? 170 : 0; easing.type: Easing.OutBack }
    }

    Item {
        id: content
        x: kl.scrollX
        width: te.width
        height: kl.implicitHeight

        TextEdit {
            id: te
            y: kl.reserve
            width: kl.wrap ? kl.width : contentWidth
            text: kl.text
            color: kl.color
            readOnly: true
            enabled: false
            selectByMouse: false
            activeFocusOnPress: false
            textFormat: TextEdit.PlainText
            wrapMode: kl.wrap ? TextEdit.Wrap : TextEdit.NoWrap
            horizontalAlignment: kl.wrap ? TextEdit.AlignHCenter : TextEdit.AlignLeft
            font.pixelSize: kl.pixelSize
            font.bold: kl.bold
            font.family: kl.family

            onTextChanged: kl.schedule()
            onContentWidthChanged: kl.schedule()
            onContentHeightChanged: kl.schedule()

            Behavior on color { ColorAnimation { duration: 250 } }
        }

        Rectangle {
            id: core
            width: kl.dotSize
            height: kl.dotSize
            radius: width / 2
            color: kl.dotColor
            x: kl.dotX - width / 2
            y: kl.dotYpos
            opacity: kl.showDot ? 1 : 0

            Behavior on opacity { NumberAnimation { duration: 160 } }

            transform: Scale {
                origin.x: core.width / 2
                origin.y: core.height
                xScale: 1 - 0.2 * kl.sq
                yScale: 1 + 0.3 * kl.sq
            }
        }
    }
}
