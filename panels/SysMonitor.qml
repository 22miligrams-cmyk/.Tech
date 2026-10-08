import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

PanelWindow {
    id: mon

    function tr(key) { return Tr.tr(key) }

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass

    property string side: "bottom"

    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property color warmColor: "#fab387"
    readonly property color hotColor: "#f38ba8"

    property string cpuName: ""
    property real cpuMhz: 0
    property real cpuUsage: 0
    property var cores: []
    property var mem: ({})
    property real uptime: 0
    property string load: ""
    property real diskUsed: 0
    property real diskSize: 0
    property var temps: []
    property var fans: []
    property var gpu: null

    readonly property var cpuChips: ["k10temp", "coretemp", "zenpower", "cpu_thermal"]

    function pickCpuTemp() {
        let best = null
        for (let i = 0; i < temps.length; i++) {
            const t = temps[i]
            if (cpuChips.indexOf(t.chip) < 0) continue
            if (/Tctl|Tdie|Package/i.test(t.label)) return t.c
            if (best === null) best = t.c
        }
        return best
    }
    readonly property var cpuTemp: pickCpuTemp()

    function otherTemps() {
        const out = []
        for (let i = 0; i < temps.length; i++) {
            const t = temps[i]
            if (cpuChips.indexOf(t.chip) >= 0) continue
            if (!(t.c > 0 && t.c < 150)) continue
            const nice = /^temp\d+$/.test(t.label) ? t.chip : t.chip + " " + t.label
            out.push({ name: nice, c: t.c })
            if (out.length >= 10) break
        }
        return out
    }

    function num(s) {
        const v = parseFloat(s)
        return isNaN(v) ? -1 : v
    }

    function parse(text) {
        const lines = text.split("\n")
        const newTemps = []
        const newFans = []
        const newMem = {}
        let newGpu = null

        for (let i = 0; i < lines.length; i++) {
            const f = lines[i].split("|")
            switch (f[0]) {
            case "cpuname": cpuName = (f[1] || "").replace(/\(R\)|\(TM\)|CPU|Processor/g, "").replace(/\s+/g, " ").trim(); break
            case "cpumhz": cpuMhz = num(f[1]); break
            case "mem": newMem[f[1]] = Number(f[2]); break
            case "uptime": uptime = num(f[1]); break
            case "load": load = f[1] || ""; break
            case "disk": diskUsed = num(f[1]); diskSize = num(f[2]); break
            case "temp": newTemps.push({ chip: f[1], label: f[2], c: num(f[3]) }); break
            case "fan": newFans.push({ chip: f[1], label: f[2], rpm: num(f[3]) }); break
            case "gpu": {
                const g = (f[1] || "").split(",").map(s => s.trim())
                if (g.length >= 10) {
                    newGpu = {
                        name: g[0].replace(/NVIDIA |GeForce /g, ""),
                        util: num(g[1]), temp: num(g[2]), fan: num(g[3]),
                        memUsed: num(g[4]), memTotal: num(g[5]),
                        power: num(g[6]), powerLimit: num(g[7]),
                        clkGr: num(g[8]), clkMem: num(g[9])
                    }
                }
                break
            }
            }
        }
        temps = newTemps
        fans = newFans
        mem = newMem
        gpu = newGpu
    }

    property var prevTotal: []
    property var prevIdle: []

    function parseStat(t) {
        const lines = t.split("\n")
        const totals = []
        const idles = []
        for (let i = 0; i < lines.length; i++) {
            if (!/^cpu\d*\s/.test(lines[i])) continue
            const f = lines[i].trim().split(/\s+/)
            let total = 0
            for (let k = 1; k <= 8; k++) total += Number(f[k])
            totals.push(total)
            idles.push(Number(f[4]))
        }
        if (prevTotal.length === totals.length && totals.length > 1) {
            const usage = []
            for (let i = 0; i < totals.length; i++) {
                const d = totals[i] - prevTotal[i]
                usage.push(d > 0 ? Math.max(0, Math.min(100, 100 * (d - (idles[i] - prevIdle[i])) / d)) : 0)
            }
            cpuUsage = usage[0]
            cores = usage.slice(1)
        }
        prevTotal = totals
        prevIdle = idles
    }

    function gb(kb) {
        return (kb / 1048576).toFixed(1)
    }
    function fmtUptime(s) {
        const d = Math.floor(s / 86400)
        const h = Math.floor((s % 86400) / 3600)
        const m = Math.floor((s % 3600) / 60)
        if (d > 0) return d + tr("unit.d") + " " + h + tr("unit.h")
        if (h > 0) return h + tr("unit.h") + " " + m + tr("unit.m")
        return m + tr("unit.m")
    }

    function tempColor(c) {
        if (c >= 85) return hotColor
        if (c >= 72) return warmColor
        return colText
    }
    readonly property real memTotal: mem.MemTotal || 0
    readonly property real memUsed: memTotal - (mem.MemAvailable || 0)
    readonly property real swapTotal: mem.SwapTotal || 0
    readonly property real swapUsed: swapTotal - (mem.SwapFree || 0)

    readonly property string collectScript: `
awk -F': *' '/^model name/ && !m {m=$2} /^cpu MHz/ {s+=$2; n++} END {if (m != "") print "cpuname|" m; if (n) print "cpumhz|" int(s/n)}' /proc/cpuinfo
awk '/^MemTotal|^MemAvailable|^SwapTotal|^SwapFree/ {gsub(":","",$1); print "mem|" $1 "|" $2}' /proc/meminfo
read -r up _ < /proc/uptime; echo "uptime|$up"
read -r l1 l2 l3 _ < /proc/loadavg; echo "load|$l1 $l2 $l3"
df -B1 --output=used,size / | tail -1 | awk '{print "disk|" $1 "|" $2}'
for h in /sys/class/hwmon/hwmon*; do
  [ -d "$h" ] || continue
  n=""; read -r n 2>/dev/null < "$h/name"
  for t in "$h"/temp*_input; do
    [ -f "$t" ] || continue
    read -r v 2>/dev/null < "$t" || continue
    l=""; read -r l 2>/dev/null < "\${t%_input}_label"
    if [ -z "$l" ]; then l="\${t##*/}"; l="\${l%_input}"; fi
    echo "temp|$n|$l|$((v / 1000))"
  done
  for f in "$h"/fan*_input; do
    [ -f "$f" ] || continue
    read -r v 2>/dev/null < "$f" || continue
    l=""; read -r l 2>/dev/null < "\${f%_input}_label"
    if [ -z "$l" ]; then l="\${f##*/}"; l="\${l%_input}"; fi
    echo "fan|$n|$l|$v"
  done
done
nvidia-smi -i 0 --query-gpu=name,utilization.gpu,temperature.gpu,fan.speed,memory.used,memory.total,power.draw,power.limit,clocks.gr,clocks.mem --format=csv,noheader,nounits 2>/dev/null | sed 's/^/gpu|/'
`

    Process {
        id: poll
        command: ["bash", "-c", mon.collectScript]
        stdout: StdioCollector {
            onStreamFinished: mon.parse(text)
        }
    }

    FileView {
        id: statFile
        path: "/proc/stat"
        onLoaded: mon.parseStat(statFile.text())
    }

    Timer {
        interval: 2000
        running: mon.visible && !mon.isClosing
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!poll.running) poll.running = true
    }
    Timer {
        interval: 1000
        running: mon.visible && !mon.isClosing
        repeat: true
        triggeredOnStart: true
        onTriggered: statFile.reload()
    }

    readonly property bool horiz: side === "top" || side === "bottom"
    readonly property real pad: 14
    readonly property real cr: 6
    readonly property real pw: horiz ? Math.max(370, anchorRect.w) : 370
    readonly property real ph: Math.min(body.implicitHeight + pad * 2, height - 100)

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(v, hi))
    }

    readonly property bool fused: horiz ? anchorRect.w > 0 : anchorRect.h > 0
    readonly property real gapNow: 0

    readonly property real px: side === "left" ? anchorRect.x + anchorRect.w + gapNow
        : side === "right" ? anchorRect.x - pw - gapNow
        : clamp(anchorRect.x + anchorRect.w / 2 - pw / 2, 8, width - 8 - pw)

    readonly property real py: side === "bottom" ? anchorRect.y - ph - gapNow
        : side === "top" ? anchorRect.y + anchorRect.h + gapNow
        : clamp(anchorRect.y + anchorRect.h / 2 - ph / 2, 8, height - 8 - ph)

    function sq(v) {
        if (!fused) return false
        const sp = anchorRect.spans
        if (sp) {
            for (let i = 0; i < sp.length; i++)
                if (v >= sp[i][0] - 0.5 && v <= sp[i][1] + 0.5) return true
            return false
        }
        return v >= anchorRect.lo - 0.5 && v <= anchorRect.hi + 0.5
    }

    readonly property bool covers: fused && (horiz
        ? (px <= anchorRect.x + 0.5 && px + pw >= anchorRect.x + anchorRect.w - 0.5)
        : (py <= anchorRect.y + 0.5 && py + ph >= anchorRect.y + anchorRect.h - 0.5))

    property bool isClosing: false
    property real p: 0

    function toggleMenu() {
        if (isClosing)
            return

        if (visible) {
            isClosing = true
            openAnim.stop()
            closeAnim.start()
        } else {
            p = 0
            prevTotal = []
            visible = true
            openAnim.restart()
            keys.forceActiveFocus()
        }
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "sysmonitor-menu"
    visible: false

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    LiveBackdrop {
        id: backdrop
        screenObj: mon.screen
        wallpaper: mon.wallpaper
        autoDetect: false
        active: mon.visible && mon.blurEnabled
        roi: Qt.rect(mon.px, mon.py, mon.pw, mon.ph)
        pollInterval: 700
        texScale: 0.5
        x: -width - 64
        y: -height - 64
    }

    component Lbl: Text {
        property real px: 11
        font.pixelSize: px
        font.bold: true
        font.family: "JetBrainsMono Nerd Font, Monospace"
    }

    component IconLbl: Row {
        id: il
        property string icon: ""
        property string text: ""
        property color color: "white"
        property real iconDim: 1.3
        spacing: 6

        Icon {
            name: il.icon
            size: 14
            color: il.color
            dim: il.iconDim
            anchors.verticalCenter: parent.verticalCenter
        }

        Lbl { text: il.text; color: il.color }
    }

    component Meter: Item {
        property real value: 0
        property color fill
        property color track
        height: 6

        Rectangle {
            anchors.fill: parent
            radius: 3
            color: parent.track


            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, parent.parent.value))
                height: parent.height
                radius: 3
                color: parent.parent.fill

                Behavior on width { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
            }
        }
    }

    component Card: Rectangle {
        default property alias content: col.data
        property color tint
        radius: 6
        color: tint
        implicitHeight: col.implicitHeight + 20

        Column {
            id: col
            x: 10
            y: 10
            width: parent.width - 20
            spacing: 7
        }
    }

    component KV: Column {
        property string k
        property string v
        property color kc
        property color vc
        spacing: 1

        Lbl { text: parent.k; px: 10; color: parent.kc }
        Lbl { text: parent.v; px: 11; color: parent.vc }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: mon.toggleMenu()

        MouseArea {
            anchors.fill: parent
            onClicked: mon.toggleMenu()
        }

        NumberAnimation {
            id: openAnim
            target: mon
            property: "p"
            to: 1
            duration: 300
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: closeAnim
            target: mon
            property: "p"
            to: 0
            duration: 210
            easing.type: Easing.InCubic
            onFinished: {
                mon.visible = false
                mon.isClosing = false
            }
        }

        Item {
            id: holder
            x: mon.px
            y: mon.py
            width: mon.pw
            height: mon.ph
            clip: true

            BarBlur {
                source: (mon.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: holder.x
                originY: holder.y
                rect: ({ x: panel.x, y: panel.y, w: panel.width, h: panel.height })
                corners: Qt.vector4d(panel.topLeftRadius, panel.topRightRadius,
                                     panel.bottomRightRadius, panel.bottomLeftRadius)
                blurRadius: mon.blurRadius
                tint: mon.blurTint
                strength: panel.opacity
            }

            Rectangle {
                id: panel
                width: holder.width
                height: holder.height

                x: mon.side === "left" ? -(1 - mon.p) * width
                 : mon.side === "right" ? (1 - mon.p) * width : 0
                y: mon.side === "bottom" ? (1 - mon.p) * height
                 : mon.side === "top" ? -(1 - mon.p) * height : 0
                opacity: Math.min(1, mon.p * 2.5)

                color: mon.colGlass

                topLeftRadius: ((mon.side === "top" && mon.sq(mon.px)) || (mon.side === "left" && mon.sq(mon.py))) ? 0 : mon.cr
                topRightRadius: ((mon.side === "top" && mon.sq(mon.px + mon.pw)) || (mon.side === "right" && mon.sq(mon.py))) ? 0 : mon.cr
                bottomLeftRadius: ((mon.side === "bottom" && mon.sq(mon.px)) || (mon.side === "left" && mon.sq(mon.py + mon.ph))) ? 0 : mon.cr
                bottomRightRadius: ((mon.side === "bottom" && mon.sq(mon.px + mon.pw)) || (mon.side === "right" && mon.sq(mon.py + mon.ph))) ? 0 : mon.cr

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => mouse.accepted = true
                }

                Flickable {
                    id: flick
                    x: mon.pad
                    y: mon.pad
                    width: parent.width - mon.pad * 2
                    height: parent.height - mon.pad * 2
                    contentWidth: width
                    contentHeight: body.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: body
                        width: flick.width
                        spacing: 8

                        readonly property color cardTint: Qt.alpha(mon.colText, 0.06)
                        readonly property color dim: Qt.alpha(mon.colText, 0.55)
                        readonly property color track: Qt.alpha(mon.colText, 0.14)

                        Item {
                            width: parent.width
                            height: 28

                            Row {
                                spacing: 10

                                Rectangle {
                                    width: 28
                                    height: 28
                                    radius: mon.cr
                                    color: mon.colSecondary

                                    Icon {
                                        anchors.centerIn: parent
                                        name: "ram"
                                        size: 15
                                        color: mon.colAccent
                                        dim: 1.3
                                    }
                                }

                                Lbl {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: tr("sys.title")
                                    px: 15
                                    color: mon.colText
                                }
                            }

                            IconLbl {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                icon: "clock12"
                                text: mon.fmtUptime(mon.uptime)
                                color: body.dim
                                iconDim: 1.0
                            }
                        }
                        Card {
                            width: parent.width
                            tint: body.cardTint

                            Item {
                                width: parent.width
                                height: 18

                                IconLbl { icon: "sys"; text: "CPU"; color: mon.colAccent }
                                Row {
                                    anchors.right: parent.right
                                    spacing: 10

                                    Lbl {
                                        visible: mon.cpuTemp !== null
                                        text: Math.round(mon.cpuTemp) + "°C"
                                        color: mon.tempColor(mon.cpuTemp)
                                    }
                                    Lbl { text: Math.round(mon.cpuUsage) + "%"; color: mon.colText }
                                }
                            }

                            Lbl {
                                width: parent.width
                                text: mon.cpuName
                                px: 10
                                color: body.dim
                                elide: Text.ElideRight
                            }
                            Meter {
                                width: parent.width
                                value: mon.cpuUsage / 100
                                fill: mon.colAccent
                                track: body.track
                            }

                            Row {
                                id: coreRow
                                width: parent.width
                                height: 30
                                spacing: 2
                                visible: mon.cores.length > 0

                                Repeater {
                                    model: mon.cores

                                    Item {
                                        required property real modelData
                                        width: Math.max(2, (coreRow.width - (mon.cores.length - 1) * coreRow.spacing) / mon.cores.length)
                                        height: coreRow.height


                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 2
                                            color: body.track
                                        }
                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            height: Math.max(2, parent.height * parent.modelData / 100)
                                            radius: 2
                                            color: parent.modelData > 85 ? mon.hotColor : mon.colAccent

                                            Behavior on height { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
                                        }
                                    }
                                }
                            }

                            Row {
                                width: parent.width

                                KV {
                                    width: parent.width / 3
                                    k: tr("sys.freq")
                                    v: mon.cpuMhz > 0 ? (mon.cpuMhz / 1000).toFixed(2) + " GHz" : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                                KV {
                                    width: parent.width / 3
                                    k: tr("sys.cores")
                                    v: mon.cores.length > 0 ? String(mon.cores.length) : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                                KV {
                                    width: parent.width / 3
                                    k: "Load avg"
                                    v: mon.load !== "" ? mon.load : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                            }
                        }

                        Card {
                            visible: mon.gpu !== null
                            width: parent.width
                            tint: body.cardTint

                            Item {
                                width: parent.width
                                height: 18

                                IconLbl { icon: "gpu"; text: "GPU"; color: mon.colAccent }
                                Row {
                                    anchors.right: parent.right
                                    spacing: 10

                                    Lbl {
                                        visible: mon.gpu !== null && mon.gpu.temp >= 0
                                        text: mon.gpu ? Math.round(mon.gpu.temp) + "°C" : ""
                                        color: mon.gpu ? mon.tempColor(mon.gpu.temp) : mon.colText
                                    }
                                    Lbl {
                                        text: mon.gpu && mon.gpu.util >= 0 ? Math.round(mon.gpu.util) + "%" : "N/A"
                                        color: mon.colText
                                    }
                                }
                            }

                            Lbl {
                                width: parent.width
                                text: mon.gpu ? mon.gpu.name : ""
                                px: 10
                                color: body.dim
                                elide: Text.ElideRight
                            }

                            Meter {
                                width: parent.width
                                value: mon.gpu && mon.gpu.util >= 0 ? mon.gpu.util / 100 : 0
                                fill: mon.colAccent
                                track: body.track
                            }

                            Item {
                                width: parent.width
                                height: 14

                                Lbl { text: "VRAM"; px: 10; color: body.dim }
                                Lbl {
                                    anchors.right: parent.right
                                    px: 10
                                    color: mon.colText
                                    text: mon.gpu && mon.gpu.memTotal > 0
                                        ? (mon.gpu.memUsed / 1024).toFixed(1) + " / " + (mon.gpu.memTotal / 1024).toFixed(1) + " GB"
                                        : "—"
                                }
                            }

                            Meter {
                                width: parent.width
                                value: mon.gpu && mon.gpu.memTotal > 0 ? mon.gpu.memUsed / mon.gpu.memTotal : 0
                                fill: mon.colAccent
                                track: body.track
                            }

                            Row {
                                width: parent.width

                                KV {
                                    width: parent.width / 3
                                    k: tr("sys.fan")
                                    v: mon.gpu && mon.gpu.fan >= 0 ? Math.round(mon.gpu.fan) + "%" : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                                KV {
                                    width: parent.width / 3
                                    k: tr("sys.power")
                                    v: mon.gpu && mon.gpu.power >= 0
                                        ? Math.round(mon.gpu.power) + (mon.gpu.powerLimit > 0 ? " / " + Math.round(mon.gpu.powerLimit) : "") + " W"
                                        : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                                KV {
                                    width: parent.width / 3
                                    k: tr("sys.clocks")
                                    v: mon.gpu && mon.gpu.clkGr >= 0
                                        ? Math.round(mon.gpu.clkGr) + " / " + Math.round(mon.gpu.clkMem)
                                        : "—"
                                    kc: body.dim; vc: mon.colText
                                }
                            }
                        }

                        Card {
                            width: parent.width
                            tint: body.cardTint

                            Item {
                                width: parent.width
                                height: 18

                                IconLbl { icon: "ram"; text: "RAM"; color: mon.colAccent }
                                Lbl {
                                    anchors.right: parent.right
                                    color: mon.colText
                                    text: mon.memTotal > 0 ? mon.gb(mon.memUsed) + " / " + mon.gb(mon.memTotal) + " GB" : "—"
                                }
                            }

                            Meter {
                                width: parent.width
                                value: mon.memTotal > 0 ? mon.memUsed / mon.memTotal : 0
                                fill: mon.colAccent
                                track: body.track
                            }

                            Item {
                                visible: mon.swapTotal > 0
                                width: parent.width
                                height: 14

                                Lbl { text: "Swap"; px: 10; color: body.dim }
                                Lbl {
                                    anchors.right: parent.right
                                    px: 10
                                    color: mon.colText
                                    text: mon.gb(mon.swapUsed) + " / " + mon.gb(mon.swapTotal) + " GB"
                                }
                            }
                        }

                        Card {
                            visible: mon.fans.length > 0 || (mon.gpu !== null && mon.gpu.fan >= 0)
                            width: parent.width
                            tint: body.cardTint

                            IconLbl { icon: "fan"; text: tr("sys.fans"); color: mon.colAccent }

                            Repeater {
                                model: mon.fans

                                Column {
                                    id: fanItem
                                    required property var modelData
                                    width: parent.width
                                    spacing: 3

                                    Item {
                                        width: parent.width
                                        height: 14

                                        Lbl {
                                            width: parent.width - 90
                                            px: 10
                                            color: mon.colText
                                            elide: Text.ElideRight
                                            text: /^fan\d+$/.test(fanItem.modelData.label)
                                                  ? fanItem.modelData.chip + " " + fanItem.modelData.label.replace("fan", "#")
                                                  : fanItem.modelData.label
                                        }
                                        Lbl {
                                            anchors.right: parent.right
                                            px: 10
                                            color: fanItem.modelData.rpm > 0 ? mon.colText : body.dim
                                            text: fanItem.modelData.rpm + " RPM"
                                        }
                                    }
                                    Meter {
                                        width: parent.width
                                        height: 4
                                        value: fanItem.modelData.rpm / 3000
                                        fill: mon.colAccent
                                        track: body.track
                                    }
                                }
                            }

                            Column {
                                visible: mon.gpu !== null && mon.gpu.fan >= 0
                                width: parent.width
                                spacing: 3

                                Item {
                                    width: parent.width
                                    height: 14

                                    Lbl { text: "GPU"; px: 10; color: mon.colText }
                                    Lbl {
                                        anchors.right: parent.right
                                        px: 10
                                        color: mon.colText
                                        text: mon.gpu ? Math.round(mon.gpu.fan) + " %" : ""
                                    }
                                }

                                Meter {
                                    width: parent.width
                                    height: 4
                                    value: mon.gpu ? mon.gpu.fan / 100 : 0
                                    fill: mon.colAccent
                                    track: body.track
                                }
                            }
                        }
                        Card {
                            id: tempCard
                            readonly property var items: mon.otherTemps()
                            visible: items.length > 0
                            width: parent.width
                            tint: body.cardTint

                            IconLbl { icon: "temp"; text: tr("sys.temps"); color: mon.colAccent }

                            Grid {
                                columns: 2
                                width: parent.width
                                columnSpacing: 12
                                rowSpacing: 4

                                Repeater {
                                    model: tempCard.items

                                    Item {
                                        required property var modelData
                                        width: (body.width - 20 - 12) / 2
                                        height: 14

                                        Lbl {
                                            width: parent.width - 40
                                            px: 10
                                            color: body.dim
                                            elide: Text.ElideRight
                                            text: parent.modelData.name
                                        }
                                        Lbl {
                                            anchors.right: parent.right
                                            px: 10
                                            color: mon.tempColor(parent.modelData.c)
                                            text: Math.round(parent.modelData.c) + "°C"
                                        }
                                    }
                                }
                            }
                        }

                        Card {
                            visible: mon.diskSize > 0
                            width: parent.width
                            tint: body.cardTint

                            Item {
                                width: parent.width
                                height: 18

                                IconLbl { icon: "disk"; text: tr("sys.disk"); color: mon.colAccent }
                                Lbl {
                                    anchors.right: parent.right
                                    color: mon.colText
                                    text: (mon.diskUsed / 1073741824).toFixed(0) + " / " + (mon.diskSize / 1073741824).toFixed(0) + " GB"
                                }
                            }

                            Meter {
                                width: parent.width
                                value: mon.diskSize > 0 ? mon.diskUsed / mon.diskSize : 0
                                fill: mon.diskUsed / mon.diskSize > 0.9 ? mon.hotColor : mon.colAccent
                                track: body.track
                            }
                        }
                    }
                }
            }
        }
    }
}
