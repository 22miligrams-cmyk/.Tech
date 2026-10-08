// DndSound.qml
//
// Что это: звуковая часть режима «Не беспокоить».
// Обычные уведомления глушатся в Notify.qml (просто не показываем), но мессенджеры
// (Telegram, Discord и т.д.) пищат САМИ, мимо уведомлений — через свой аудиопоток.
// Вот их-то мы тут и глушим через PipeWire, пока DND включён.
//
// Как работает, в двух словах:
//   1. берём все исходящие потоки приложений из Pipewire.nodes
//   2. те, что похожи на мессенджер/почтовик (или вообще все, если muteAll) — mute
//   3. запоминаем в saved только то, что заглушили САМИ
//   4. когда DND выключили — размьючиваем только своё, и только если mute всё ещё наш
//      (если юзер руками поменял — не трогаем, он лучше знает)
//
// Звонки (media.role = Communication/Phone) по умолчанию не трогаем, чтоб слышать собеседника.
import QtQuick
import Quickshell.Services.Pipewire
import "../bar"
import "../panels"
import "../settings"
import "../common"


Item {
    id: dnd

    property bool active: false

    // true -> глушим вообще всё (и музыку, и видео тоже)
    property bool muteAll: false

    // true -> потоки звонков не трогаем (media.role = Communication/Phone).
    // Работает только если приложение само ставит media.role, иначе глушится как обычный поток
    property bool keepCalls: true
    property var callRoles: ["communication", "phone"]

    // по этим подстрокам узнаём приложение (application.name / бинарник / node.name)
    property var apps: [
        "telegram", "ayugram", "kotatogram", "64gram",
        "discord", "vesktop", "legcord", "webcord",
        "slack", "whatsapp", "zapzap",
        "thunderbird", "evolution", "geary"
    ]
    // Короткие слова ищем только как целое слово (org.signal.Signal, element-desktop),
    // иначе "signal" цеплял бы signalk, а "element" — elementary и прочее
    property var wholeWordApps: ["signal", "element"]

    property int pollMs: 400      // страховочный опрос пока DND включён (мс)
    property int echoMs: 1000     // сколько ждём подтверждения mute от PipeWire, потом считаем что юзер снял руками

    // все исходящие аудиопотоки приложений (не sink-и)
    readonly property var streams: {
        const out = []
        const vals = Pipewire.nodes.values
        for (let i = 0; i < vals.length; i++) {
            const n = vals[i]
            if (n && n.isStream && !n.isSink) out.push(n)
        }
        return out
    }

    // id узла -> { ours: заглушили мы и он всё ещё наш, at: когда заглушили }
    property var saved: ({})

    // сколько потоков ещё надо вернуть обратно (держит привязку и опрос даже после выключения DND)
    property int heldCount: 0

    // без привязки у узла нет ни audio, ни properties — поэтому трекер
    PwObjectTracker { objects: (dnd.active || dnd.heldCount > 0) ? dnd.streams : [] }


    // Проверяет, что поток — это звонок (по media.role). Нужна, чтобы не глушить собеседника
    function isCall(p) {
        const r = String(p["media.role"] || "").toLowerCase()
        return r !== "" && callRoles.indexOf(r) >= 0
    }

    // Решает, надо ли глушить этот поток: звонки пропускаем, при muteAll глушим всё,
    // иначе ищем имя приложения в списках apps / wholeWordApps
    function matches(n) {
        const p = n.properties || {}
        if (keepCalls && isCall(p)) return false
        if (muteAll) return true

        const s = ((p["application.name"] || "") + " " + (p["application.process.binary"] || "")
                   + " " + (p["node.name"] || "")).toLowerCase()

        for (let i = 0; i < apps.length; i++) if (s.indexOf(apps[i]) >= 0) return true

        const words = s.split(/[^a-z0-9]+/)
        for (let i = 0; i < wholeWordApps.length; i++) if (words.indexOf(wholeWordApps[i]) >= 0) return true
        return false
    }

    // Главная функция: проходит по всем потокам и приводит mute в нужное состояние.
    // Глушит подходящие, возвращает звук тем, что глушили сами, забывает пропавшие потоки.
    // off = true — принудительно всё вернуть как было (зовём при уничтожении элемента)
    function sync(off) {
        const on = active && !off
        if (!on && heldCount === 0) return

        const now = Date.now()
        const alive = {}

        for (let i = 0; i < streams.length; i++) {
            const n = streams[i]
            alive[n.id] = true
            if (!n.audio) continue

            const e = saved[n.id]

            if (on && matches(n)) {
                if (!e) {
                    if (n.audio.muted) {
                        saved[n.id] = { ours: false, at: 0 }     // уже был заглушен не нами — не лезем
                    } else {
                        n.audio.muted = true
                        saved[n.id] = { ours: true, at: now }
                    }
                } else if (e.ours && !n.audio.muted) {
                    if (now - e.at < echoMs) n.audio.muted = true   // PipeWire ещё не успел подтвердить
                    else e.ours = false                             // размьютили руками — больше не вмешиваемся
                }
            } else if (e) {
                if (e.ours && n.audio.muted) n.audio.muted = false  // возвращаем, только если mute всё ещё наш
                delete saved[n.id]
            }
        }

        // потоки, которых уже нет, забываем
        for (const id in saved) if (!alive[id]) delete saved[id]
        heldCount = Object.keys(saved).length
    }

    onActiveChanged: sync()
    onStreamsChanged: sync()
    Component.onDestruction: sync(true)


    // Новые потоки (звук нового сообщения) привязываются не сразу, так что на всякий случай
    // ещё и опрашиваем по таймеру. Основная реакция всё равно идёт через onStreamsChanged
    Timer {
        interval: dnd.pollMs
        repeat: true
        running: dnd.active || dnd.heldCount > 0
        onTriggered: dnd.sync()
    }
}
