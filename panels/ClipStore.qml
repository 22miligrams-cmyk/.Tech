import QtQuick
import Quickshell
import Quickshell.Io
import "../bar"
import "../notifications"
import "../settings"
import "../common"

Item {
    id: store

    property alias history: hist
    readonly property int count: hist.count

    property bool watching: true
    property int maxItems: 30
    property int maxImages: 10
    property int maxChars: 4000
    property int nextUid: 1

    property bool textPaused: false
    property bool imagePaused: false

    readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/qs-clip"
    readonly property string imgDir: dataDir + "/img"
    readonly property string historyPath: dataDir + "/history.json"

    property bool loaded: false

    ListModel { id: hist }

    function dropFile(path) {
        if (path !== "") Quickshell.execDetached(["rm", "-f", path])
    }

    function imageCount() {
        let n = 0
        for (let i = 0; i < hist.count; i++) if (hist.get(i).kind === "image") n++
        return n
    }

    function removeAt(i, keepFile) {
        const e = hist.get(i)
        if (e.kind === "image" && !keepFile) dropFile(e.path)
        hist.remove(i)
        scheduleSave()
    }
    function trim() {
        while (imageCount() > maxImages) {
            for (let i = hist.count - 1; i >= 0; i--) {
                if (hist.get(i).kind === "image") { removeAt(i, false); break }
            }
        }
        while (hist.count > maxItems) removeAt(hist.count - 1, false)
    }

    function push(e) {
        e.uid = nextUid++
        e.timeText = Qt.formatTime(new Date(), "HH:mm")
        hist.insert(0, e)
        trim()
        scheduleSave()
    }

    function addText(t) {
        if (typeof t !== "string" || t.trim() === "") return
        if (t.length > maxChars) t = t.substring(0, maxChars)

        for (let i = 0; i < hist.count; i++) {
            const e = hist.get(i)
            if (e.kind === "text" && e.text === t) { removeAt(i, false); break }
        }

        push({ kind: "text", text: t, chars: t.length, path: "", mime: "", bytes: 0 })
    }

    function addImage(path, mime, bytes) {
        if (!path) return

        for (let i = 0; i < hist.count; i++) {
            const e = hist.get(i)
            if (e.kind === "image" && e.path === path) { removeAt(i, true); break }
        }

        push({ kind: "image", text: "", chars: 0, path: path, mime: mime || "image/png", bytes: bytes || 0 })
    }

    function handle(line) {
        let o
        try { o = JSON.parse(line) } catch (e) { console.warn("ClipStore:", line); return }
        if (!o) return
        if (o.kind === "image") addImage(o.path, o.mime, o.bytes)
        else if (o.kind === "text") addText(o.text)
    }

    function remove(uid) {
        for (let i = 0; i < hist.count; i++) {
            if (hist.get(i).uid === uid) { removeAt(i, false); return }
        }
    }

    function clear() {
        for (let i = 0; i < hist.count; i++) {
            const e = hist.get(i)
            if (e.kind === "image") dropFile(e.path)
        }
        hist.clear()
        scheduleSave()
    }

    function copyEntry(kind, text, path, mime) {
        if (kind === "image")
            copyProc.command = ["bash", "-c", "wl-copy --type \"$2\" < \"$1\"", "_", path, mime]
        else
            copyProc.command = ["bash", "-c", "printf %s \"$1\" | wl-copy", "_", text]
        copyProc.running = true
    }


    Process { id: copyProc }

    function scheduleSave() {
        if (loaded) saveTimer.restart()
    }

    function chunks(str, size) {
        const out = []
        let i = 0
        while (i < str.length) {
            let end = Math.min(i + size, str.length)
            if (end < str.length) {
                const c = str.charCodeAt(end - 1)
                if (c >= 0xD800 && c <= 0xDBFF) end--
            }
            out.push(str.substring(i, end))
            i = end
        }
        return out
    }

    function serialize() {
        const arr = []

        for (let i = hist.count - 1; i >= 0; i--) {
            const e = hist.get(i)
            arr.push({ kind: e.kind, text: e.text, chars: e.chars, path: e.path,
                       mime: e.mime, bytes: e.bytes, timeText: e.timeText })
        }
        return JSON.stringify(arr)
    }

    function saveNow() {
        if (saveProc.running) { saveTimer.restart(); return }
        const parts = chunks(serialize(), 30000)
        saveProc.command = ["bash", "-c",
            "f=\"$1\"; shift; mkdir -p \"$(dirname \"$f\")\" || exit 1; : > \"$f.tmp\" || exit 1; " +
            "for c in \"$@\"; do printf '%s' \"$c\" >> \"$f.tmp\"; done; mv -f \"$f.tmp\" \"$f\"",
            "_", historyPath].concat(parts.length > 0 ? parts : ["[]"])
        saveProc.running = true
    }

    Process {
        id: saveProc
        stderr: SplitParser { onRead: data => console.warn("ClipStore save:", data) }
    }

    Timer {
        id: saveTimer
        interval: 600
        onTriggered: store.saveNow()
    }

    function restore(raw) {
        let arr = []
        let ok = false

        if (raw && raw.trim() !== "") {
            try {
                const parsed = JSON.parse(raw)
                if (Array.isArray(parsed)) { arr = parsed; ok = true }
            } catch (e) {
                console.warn("ClipStore: history.json повреждён")

                Quickshell.execDetached(["cp", "-f", historyPath, historyPath + ".bad"])
            }
        }
        let added = 0

        for (let i = arr.length - 1; i >= 0; i--) {
            const o = arr[i]
            if (!o) continue
            let dup = false
            for (let j = 0; j < hist.count; j++) {
                const e = hist.get(j)
                if (o.kind === "text" && e.kind === "text" && e.text === o.text) { dup = true; break }
                if (o.kind === "image" && e.kind === "image" && e.path === o.path) { dup = true; break }
            }
            if (dup) continue

            if (o.kind === "text" && typeof o.text === "string" && o.text !== "") {
                hist.append({ uid: nextUid++, kind: "text", text: o.text, chars: o.chars || o.text.length,
                              path: "", mime: "", bytes: 0, timeText: o.timeText || "" })
                added++
            } else if (o.kind === "image" && o.path) {
                hist.append({ uid: nextUid++, kind: "image", text: "", chars: 0, path: o.path,
                              mime: o.mime || "image/png", bytes: o.bytes || 0, timeText: o.timeText || "" })
                added++
            }
        }
        trim()

        if (ok) runGc()

        console.warn("ClipStore: история загружена, записей из файла:", added, ", всего:", hist.count)
        loaded = true
        if (hist.count > 0) saveTimer.restart()
    }

    function runGc() {
        const keep = []
        for (let i = 0; i < hist.count; i++) {
            const e = hist.get(i)
            if (e.kind === "image") keep.push(e.path)
        }
        gcProc.command = ["bash", "-c",
            "cd \"$1\" 2>/dev/null || exit 0; shift; find . -maxdepth 1 -name '.tmp.*' -mmin +1 -delete; " +
            "for f in $(find . -maxdepth 1 -type f ! -name '.tmp.*' -mmin +1 -printf '%f\\n'); do k=0; " +
            "for p in \"$@\"; do [ \"$p\" = \"$PWD/$f\" ] && k=1; done; " +
            "[ $k = 1 ] || rm -f \"$f\"; done",
            "_", imgDir].concat(keep)
        gcProc.running = true
    }

    Process { id: gcProc }

    Process {
        id: loadProc
        command: ["bash", "-c", "mkdir -p \"$2\"; cat \"$1\" 2>/dev/null; exit 0", "_", store.historyPath, store.imgDir]
        running: true
        stdout: StdioCollector {
            id: loadOut
            onStreamFinished: if (!store.loaded) store.restore(text)
        }
    }

    Timer {
        interval: 5000
        running: true
        onTriggered: if (!store.loaded) console.warn("ClipStore: чтение истории не завершилось, сохранение отключено")
    }

    readonly property string imageScript: `
exec 2>&1
cat > /dev/null
d="$1"
mkdir -p "$d" || exit 0
types=$(timeout 3 wl-paste --list-types) || exit 0
case "$types" in *x-kde-passwordManagerHint*) exit 0;; esac
mime=$(printf '%s\n' "$types" | grep -m1 '^image/png$' || printf '%s\n' "$types" | grep -m1 '^image/')
[ -n "$mime" ] || exit 0
tmp="$d/.tmp.$$"
timeout 5 wl-paste --type "$mime" > "$tmp" || { rm -f "$tmp"; exit 0; }
size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
if [ "$size" -gt 0 ] && [ "$size" -le 25000000 ]; then
    ext=$(printf '%s' "$mime" | sed 's|image/||; s|jpeg|jpg|; s|[^a-zA-Z0-9]|_|g')
    h=$(sha1sum "$tmp" | cut -c1-16)
    f="$d/$h.$ext"
    mv -f "$tmp" "$f"
    printf '{"kind":"image","mime":"%s","path":"%s","bytes":%s}\n' "$mime" "$f" "$size"
else
    rm -f "$tmp"
fi
`

    Process {
        id: textWatcher
        command: ["wl-paste", "--type", "text", "--watch", "jq", "-Rsc", "."]
        running: store.watching && !store.textPaused
        stdout: SplitParser {
            onRead: data => {
                try { store.addText(JSON.parse(data)) } catch (e) { console.warn("ClipStore text:", data) }
            }
        }
        stderr: SplitParser {
            onRead: data => console.warn("ClipStore text stderr:", data)
        }
        onExited: (code, status) => {
            console.warn("ClipStore: text watcher exited, code", code)


            if (store.watching) { store.textPaused = true; textRestart.restart() }
        }
    }

    Timer {
        id: textRestart
        interval: 5000
        onTriggered: store.textPaused = false
    }

    Process {
        id: watcher
        command: ["wl-paste", "--watch", "bash", "-c", store.imageScript, "_", store.imgDir]
        running: store.watching && !store.imagePaused
        stdout: SplitParser {
            onRead: data => store.handle(data)
        }
        stderr: SplitParser {
            onRead: data => console.warn("ClipStore image stderr:", data)
        }
        onExited: (code, status) => {
            console.warn("ClipStore: image watcher exited, code", code)
            if (store.watching) { store.imagePaused = true; restartTimer.restart() }
        }
    }

    Timer {
        id: restartTimer
        interval: 5000
        onTriggered: store.imagePaused = false
    }
}
