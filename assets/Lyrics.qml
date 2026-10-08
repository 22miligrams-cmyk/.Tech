// Зачем это: чтобы в баре шёл караоке-текст того, что играет прямо сейчас.
// Берёт трек из MPRIS (Spotify, браузер, mpd...), ищет к нему синхронный .lrc:
// сначала в своей папке assets, потом в LRCLIB, а если не нашлось - слушает
// звук через songrec и пробует снова. UI тут нет, только данные (текущая
// строка, слово, статус), рисует их уже панель / бар.
// Ниже подробная шпаргалка по свойствам - оставил как есть, она полезная.

// Lyrics.qml — синхронный текст песни для текущего трека (без UI, только данные).
//
// Подключение (в Visual.qml, рядом с MprisPanel):
//     Lyrics { id: lyrics; player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null }
// Использование:
//     lyrics.currentLine   — строка, которая поёт сейчас ("" — пауза/проигрыш)
//     lyrics.nextLine      — следующая строка
//     lyrics.lines         — весь текст [{t, text}], lyrics.currentIndex — индекс текущей
//     lyrics.status        — idle | searching | recognizing | confirm | found | notfound | ad | video | hidden
//     lyrics.kind          — music | unknown | video | ad — что сейчас играет (см. classify()); lyrics.markMusic() — «это всё-таки музыка»
//     lyrics.suggestion    — при status == "confirm": {file, title} — «это оно?»; lyrics.confirmYes() / lyrics.confirmNo()
//     lyrics.candidates    — варианты для ручного выбора; lyrics.searchManual("запрос"); lyrics.pick(c); lyrics.manualState — idle | busy | empty | error
//     lyrics.offset        — сдвиг в секундах (+ = строка появляется раньше)
//     lyrics.wrongSong()   — «не та песня»: запоминает, что этот текст не подходит, убирает текст; дальше ручной поиск
//     lyrics.hideForTrack() / lyrics.unhide() — скрыть текст для этой песни (запоминается на диске) / вернуть
//
// Локальная база: .lrc-файлы лежат рядом с Lyrics.qml (папка assets), «Артист - Название.lrc» или «Название.lrc».
//   Трек не найден точно, но в базе есть файл с похожим названием → первый раз спрашиваем «это оно?».
//   «Да» — запоминаем привязку (local.json), дальше этот трек подставляется сам. «Нет» — запоминаем отказ и ищем дальше.
//
// Цепочка: локальная база → чистка метаданных → поиск в LRCLIB с оценкой совпадения (название, артист, длительность)
//          Если играет Spotify, метаданные считаются надёжными: артист обязателен (minArtist), чужие песни с таким же названием отбрасываются,
//          первым идёт точный запрос LRCLIB /api/get (артист + название + альбом + длительность).
//          → если уверенного совпадения нет: songrec по звуку → повторный поиск → ручной выбор.
// Нужны: curl не нужен (XMLHttpRequest), songrec, parec (pipewire-pulse), timeout.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // плеер из MPRIS, за ним следим; offset - ручной сдвиг тайминга
    property var player: null;  property real offset: 0.0
    // пороги совпадения: ниже minScore - считаем что не нашли, выше goodScore - дальше не ищем
    property real minScore: 0.55       // ниже — считаем, что не нашли
    property real minName: 0.70        // название должно совпасть хотя бы настолько (чтобы не подсунуть чужой текст)
    property real goodScore: 0.78      // выше — дальше не ищем
    property real minArtist: 0.5       // Spotify / songrec: артист кандидата должен совпасть хотя бы настолько, иначе это чужая песня с таким же названием
    // остальные настройки: что скрывать, что показывать в баре, как рисовать точку
    property bool debug: true          // пишет в лог шелла, почему выбран (или не найден) текст: ищите "[Lyrics]"
    property bool notFoundFlash: false // «не найден» держим в баре несколько секунд
    property bool wordHighlight: true  // точка над словом; false — точка не рисуется, но строка всё равно прокручивается
    property string dbDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))   // локальная база .lrc — та же папка assets, где лежит этот файл
    property real exactName: 0.95      // название локального файла совпало настолько — берём без вопроса
    property real suggestName: 0.60    // совпало хотя бы настолько — спрашиваем «это оно?»
    property real adMaxLen: 30         // в браузере всё короче этого (с) считаем рекламой / шортсом
    property bool skipVideos: true     // «просто видео» не ищем и не слушаем (можно вручную: «Это музыка»)
    property bool autoHide: true       // false — режим «не пропадать»: плашка в баре остаётся при любом статусе (реклама, не найден, пауза…)
    readonly property bool pinned: !autoHide   // в баре: visible: <старое условие> || lyrics.pinned
    property bool wordJump: true       // false — точка не летит, а сразу встаёт на слово (если шелл грузит процессор / видеокарту)

    property var lines: [];  property var candidates: []
    property string status: "idle"
    property real pos: 0

    // индекс текущей строки: бинарный поиск по времени с учётом offset
    readonly property int currentIndex: {
        const L = lines, t = pos+offset
        if (L.length === 0 || t < L[0].t) return -1
        let lo = 0, hi = L.length - 1
        while (lo < hi) {
            const mid = (lo+hi+1)>>1
            if (L[mid].t <= t) lo = mid; else hi = mid - 1
        }
        return lo
    }
    // ---------- Слова внутри строки ----------
    // В LRCLIB время есть только у целой строки, поэтому время слов оценивается: длительность строки
    // делится между словами пропорционально их длине (+1 символ на паузу). Длинный проигрыш после строки
    // слова не растягивает: пение занимает не больше ~0.2 с на символ.
    // Слово: { s, e — позиции в строке, a, b — время (с), line — сама строка }.
    function wordsFor(i) {
        const L = lines
        if (i < 0 || i >= L.length) return []
        const text = L[i].text
        if (!text) return []
        const t0 = L[i].t
        const span = Math.max(0.5, (i + 1 < L.length ? L[i + 1].t : t0 + 6) - t0)
        // Слова в скобках — (бэк-вокал), [?], {…} — точка пропускает: они не получают ни времени, ни остановки.
        // Скобка без пары до конца строки не считается — иначе пропала бы вся остальная строка.
        const inside = []
        let depth = 0
        for (let c = 0; c < text.length; c++) {
            const ch = text.charAt(c)
            if ("([{（［【".indexOf(ch) >= 0) { depth++; inside.push(true) }
            else if (")]}）］】".indexOf(ch) >= 0) { if (depth > 0) depth--; inside.push(true) }
            else inside.push(depth > 0)
        }
        if (depth > 0) for (let c = 0; c < inside.length; c++) inside[c] = false

        const re = /\S+/g
        const ws = []
        let m, total = 0
        while ((m = re.exec(text)) !== null) {
            let sung = false
            for (let c = m.index; c < m.index + m[0].length; c++) if (!inside[c]) { sung = true; break }
            if (!sung) continue
            const wt = m[0].length + 1
            ws.push({ s: m.index, e: m.index + m[0].length, wt: wt, line: text })
            total += wt
        }
        if (ws.length === 0) return []
        const sing = Math.min(span * 0.9, total * 0.2)
        let acc = 0
        for (let k = 0; k < ws.length; k++) {
            ws[k].a = t0 + sing*acc/total
            acc += ws[k].wt
            ws[k].b = t0 + sing * acc / total
        }
        return ws
    }

    readonly property var curWords: wordsFor(currentIndex)       // слова текущей строки
    readonly property int wordIndex: {                            // какое слово поётся сейчас (-1 — строки нет)
        const W = curWords, t = pos + offset
        if (W.length === 0) return -1   // слово считаем всегда: по нему едет прокрутка строки, даже если точка выключена
        let k = 0
        for (let i = 0; i < W.length; i++) { if (W[i].a <= t) k = i; else break }
        return k
    }

    // текущая и следующая строки обычным текстом
    readonly property string currentLine: currentIndex >= 0 ? lines[currentIndex].text : ""
    readonly property string nextLine: currentIndex + 1 < lines.length ? lines[currentIndex + 1].text : ""

    // сырые метаданные трека прямо из плеера
    readonly property string rawTitle: player && player.trackTitle ? player.trackTitle : ""
    readonly property string rawArtist: player && player.trackArtist ? player.trackArtist : ""
    readonly property string rawAlbum: player && player.trackAlbum ? player.trackAlbum : ""
    readonly property string trackUrl: player && player.metadata && player.metadata["xesam:url"] ? String(player.metadata["xesam:url"]) : ""
    readonly property string who: ((player && player.identity ? player.identity : "") + " " + (player && player.desktopEntry ? player.desktopEntry : "")).toLowerCase()
    readonly property real trackLen: player && player.length > 0 ? player.length : 0
    // играет Spotify (приложение или веб-плеер): название и артист там чистые, им можно верить
    readonly property bool spotify: who.indexOf("spotify") >= 0 || trackUrl.toLowerCase().indexOf("open.spotify.com") >= 0 || trackUrl.indexOf("spotify:") === 0

    // состояние поиска: gen нужен чтобы выбрасывать ответы от прошлого трека, дальше кэши в памяти и привязки с диска
    property int gen: 0                 // номер поиска: устаревшие ответы отбрасываем
    property bool recTried: false;  property var memCache: ({})
    property var memMeta: ({})          // curKey → {id} (LRCLIB) или {file} (локальная база): что именно сейчас показано
    property var overrides: ({})        // key → {id}, хранится на диске
    property string curKey: ""
    property string kind: "music"      // music | unknown | video | ad

    // ---------- локальная база ----------
    property string locKey: ""        // артист|название без длительности: привязка не ломается от разной длины перезалива
    property var localMap: ({})         // locKey → {file, no:[файлы, которые отклонили]}, хранится на диске
    property var dbFiles: []            // [{file, raw, base, track, artist}]
    property var dbCb: null
    property var suggestion: null       // {file, title} при status == "confirm"

    // ==================== Чистка ====================
    // чистит строку для сравнения: нижний регистр, без скобок, feat., "official video" и прочего мусора
    function norm(s) {
        return String(s || "").toLowerCase().replace(/ё/g, "е")
            .replace(/[\(\[\{][^\)\]\}]*[\)\]\}]/g, " ")
            .replace(/\s(feat|ft|featuring|prod|при участии)\b.*$/, " ")
            .replace(/\s*[-–—]\s*topic\s*$/, " ").replace(/\bvevo\b/g, " ")
            .replace(/\b(slowed(\s+(and|n|\+|&)\s+reverb)?|sped\s*up|speed\s*up|nightcore|reverb|8d(\s+audio)?|bass\s*boosted)\b/g, " ")
            .replace(/\b(remaster(ed)?|official|video|audio|lyrics?|hd|hq|4k|клип|премьера)\b/g, " ")
            .replace(/[^a-z0-9\u00c0-\u024f\u0400-\u04ff\s]/g, " ")
            .replace(/\s+/g, " ").trim()
    }

    // строка -> набор слов (для сравнения по словам)
    function tokens(s) {
        const o = {}, a = norm(s).split(" ")
        for (let i = 0; i < a.length; i++) if (a[i]) o[a[i]] = true
        return o
    }

    // таблица транслита кириллица -> латиница
    readonly property var cyr: ({ "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z", "и": "i",
        "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e",
        "ю": "yu", "я": "ya", "і": "i", "ї": "yi", "є": "ye", "ґ": "g" })

    // кириллица → латиница: «Нервы» и «Nervy» становятся близкими строками
    function lat(s) {
        let o = ""
        for (let i = 0; i < s.length; i++) o += cyr[s[i]] !== undefined ? cyr[s[i]] : s[i]
        return o
    }

    // расстояние Левенштейна: сколько правок нужно чтобы из a получить b
    function lev(a, b) {
        if (a === b) return 0
        let prev = [], cur = []
        for (let j = 0; j <= b.length; j++) prev.push(j)
        for (let i = 1; i <= a.length; i++) {
            cur = [i]
            for (let j = 1; j <= b.length; j++)
                cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)))
            prev = cur
        }
        return prev[b.length]
    }

    // похожесть двух строк 0..1: по словам, по транслиту и по опечаткам, берём лучшее
    function sim(a, b) {
        const x = tsim(a, b)
        const la = lat(norm(a)), lb = lat(norm(b))
        if (!la || !lb) return x
        const y = tsim(la, lb)
        const z = 0.9 * (1 - lev(la, lb) / Math.max(la.length, lb.length))   // опечатки и разные транслитерации
        return Math.max(x, y, z)
    }

    // «A, B & C feat. D» → ["A", "B", "C", "D"]: у трека может быть несколько артистов, а в LRCLIB записан только один (или все)
    function splitArtists(s) {
        return String(s || "").split(/\s*(?:,|;|&|\/|×|\sx\s|\bfeat\.?\s|\bft\.?\s|\bfeaturing\b)\s*/i)
            .map(function(x) { return x.trim() }).filter(function(x) { return x })
    }

    // Насколько артист кандидата совпал с артистом варианта v: сравниваем и целиком, и по отдельным именам
    function artScore(candArtist, v) {
        const want = [v.artist].concat(v.artists || []).filter(function(x) { return x })
        const have = [candArtist].concat(splitArtists(candArtist))
        let best = 0
        for (let i = 0; i < have.length; i++)
            for (let j = 0; j < want.length; j++) best = Math.max(best, sim(have[i], want[j]))
        return best
    }

    // Spotify: «Песня - Remastered 2011», «Песня - Live at ...» → «Песня» (в LRCLIB такая запись обычно идёт без хвоста)
    function spotifyTitle(t) {
        const c = String(t || "").replace(/\s+[-–—]\s+(?:\d{4}\s+)?(?:remaster(?:ed)?|live|mono|stereo|radio\s+edit|single\s+version|album\s+version|bonus|deluxe|from\b).*$/i, "").trim()
        return c || String(t || "")
    }

    // похожесть по набору слов (Жаккар + случай "один текст целиком внутри другого")
    function tsim(a, b) {
        const A = tokens(a), B = tokens(b)
        let inter = 0, na = 0, nb = 0
        for (const k in A) { na++; if (B[k]) inter++ }
        for (const k in B) nb++
        if (na === 0 || nb === 0) return 0
        const jac = inter / (na+nb-inter)
        const cont = inter / Math.min(na, nb)     // один текст целиком входит в другой
        return Math.max(jac, cont*0.9)
    }

    // Варианты (артист, название): заголовок «Артист - Название» важнее имени канала.
    // Spotify: метаданные чистые, поэтому только пара «артист из плеера + название», без разбора дефиса в названии
    // и без перестановок (иначе «Песня - Remastered» превращается в «артиста» Песня и находится что попало)
    function buildVariants() {
        const v = [], seen = {}
        function add(a, t, strict, exact) {
            const na = norm(a), nt = norm(t), k = na + "|" + nt
            if (!nt || seen[k]) return
            seen[k] = true
            v.push({ artist: na, track: nt, artists: splitArtists(a), strict: strict === true, exact: exact || null })
        }
        if (spotify && rawArtist) {
            const list = splitArtists(rawArtist)
            const t = spotifyTitle(rawTitle)
            const exact = { track: rawTitle, artist: list.length > 0 ? list[0] : rawArtist, album: rawAlbum }
            if (list.length > 1) add(list[0], t, true, exact)       // у LRCLIB часто указан только первый артист
            add(rawArtist, t, true, list.length > 1 ? null : exact)
            return v
        }
        const m = root.rawTitle.match(/^(.+?)(?:\s*[-–—•]\s+|\s*\|\s*)(.+)$/)   // «Артист - Название», «Артист- Название», «Артист | Название», «Артист • Название»
        if (m) add(m[1], m[2])
        add(root.rawArtist, root.rawTitle)
        if (m) add(m[2], m[1])                    // «Название - Артист» (так тоже называют)
        if (m) add("", root.rawTitle)             // вдруг дефис — часть названия
        return v
    }

    // Оценка кандидата: название важнее всего; длительность у YouTube-перезаливов плавает, поэтому штрафуем мягко
    function rate(c, v) {
        const name = sim(c.trackName, v.track)
        const art = v.artist ? artScore(c.artistName, v) : 0.5
        let dur = 0.5
        if (root.trackLen > 0 && c.duration > 0) {
            const d = Math.abs(c.duration - root.trackLen)
            dur = d <= 3 ? 1 : d <= 8 ? 0.7 : d <= 20 ? 0.4 : 0.1
        }
        return { score: 0.55 * name + 0.2 * art + 0.25 * dur, name: name, art: art }
    }

    // Набор запросов: для каждого варианта — по полям, общий и только по названию
    function buildQueries(vars) {
        const out = [], seen = {}, base = "https://lrclib.net/api/search?"
        function add(url, v) { if (!seen[url]) { seen[url] = true; out.push({ url: url, v: v }) } }
        for (let i = 0; i < vars.length; i++) {
            const v = vars[i]
            // точное совпадение по четырём полям (артист, название, альбом, длительность): самый надёжный запрос, отвечает одной записью или 404
            if (v.exact && v.exact.album && root.trackLen > 0)
                add("https://lrclib.net/api/get?track_name=" + encodeURIComponent(v.exact.track) + "&artist_name=" + encodeURIComponent(v.exact.artist)
                    + "&album_name=" + encodeURIComponent(v.exact.album) + "&duration=" + Math.round(root.trackLen), v)
            if (v.artist) add(base + "track_name=" + encodeURIComponent(v.track) + "&artist_name=" + encodeURIComponent(v.artist), v)
            add(base + "q=" + encodeURIComponent((v.artist + " " + v.track).trim()), v)
            add(base + "q=" + encodeURIComponent(v.track), v)
        }
        return out
    }

    // ==================== Сеть ====================
    // сеть: флаги сбоев и повторов
    property int watchGen: -1
    property bool netFail: false      // был сетевой сбой / 5xx — тогда «ничего нет» может быть ложным
    property bool retried: false      // один автоповтор на трек
    property string lkTitle: ""       // метаданные, по которым запускали последний поиск (чтобы не дёргать текст без причины)
    property string lkArtist: ""
    property bool lateTried: false    // один отложенный повтор после «не найден» (метаданные на ютубе могли осесть позже)

    // Сторож: если запрос завис (у XMLHttpRequest нет таймаута), через 12 с перезапускаем поиск один раз
    Timer {
        id: watchdog
        interval: 12000
        onTriggered: {
            if (root.status !== "searching" || root.watchGen !== root.gen) return
            root.netFail = true
            if (!root.retried) { root.retried = true; root.startLookup() } else root.setNotFound()
        }
    }

    // повтор через 2.5 с после сетевого сбоя
    property int retryGen: -1
    Timer { id: retryTimer; interval: 2500; onTriggered: if (root.retryGen === root.gen && root.status === "searching") root.startLookup() }

    // GET в LRCLIB через XMLHttpRequest, в колбэк уходит JSON (или null если ошибка). Заодно взводит сторожа
    function http(url, cb) {
        watchGen = gen
        watchdog.restart()
        const x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            let r = null
            if (x.status === 200) { try { r = JSON.parse(x.responseText) } catch (e) {} }
            else if (x.status === 0 || x.status >= 500) root.netFail = true
            cb(r)
        }
        x.open("GET", url)
        x.setRequestHeader("Lrclib-Client", "quickshell-lyrics")
        x.send()
    }

    // разбирает .lrc в [{t, text}]; у одной строки может быть несколько меток времени
    function parseLrc(s) {
        const out = [], re = /\[(\d+):(\d+(?:\.\d+)?)\]/g
        String(s || "").split("\n").forEach(function(line) {
            const ts = []
            let m
            re.lastIndex = 0
            while ((m = re.exec(line)) !== null) ts.push(parseInt(m[1]) * 60 + parseFloat(m[2]))
            const txt = line.replace(/\[[^\]]*\]/g, "").trim()
            ts.forEach(function(t) { out.push({ t: t, text: txt }) })
        })
        out.sort(function(a, b) { return a.t - b.t })
        return out
    }

    // ставит найденный текст: для slowed / nightcore растягивает тайминги, запоминает в кэш. false - если синхронного текста нет
    function apply(rec, remember) {
        const L = parseLrc(rec.syncedLyrics)
        if (L.length === 0) return false
        // slowed / sped up / nightcore: у оригинала другая длина — растягиваем тайминги под длину этого ролика
        if (/slowed|sped\s*up|speed\s*up|nightcore/i.test(rawTitle) && rec.duration > 0 && trackLen > 0) {
            const k = trackLen / rec.duration
            if (k > 0.5 && k < 2 && Math.abs(k - 1) > 0.02) for (let i = 0; i < L.length; i++) L[i].t *= k
        }
        lines = L
        status = "found"
        if (remember) { memCache[curKey] = L; memMeta[curKey] = { id: rec.id } }
        return true
    }

    // ==================== Что играет: реклама / видео / музыка ====================
    // Метаданные MPRIS не говорят прямо, что это, поэтому оценка эвристикой (причина пишется в лог: ищите "[Lyrics] kind").
    //   ad      — реклама: заголовок «Advertisement/Реклама», рекламный url, в браузере ролик короче adMaxLen секунд
    //   music   — нативный плеер (Spotify, mpd…), music.youtube.com, SoundCloud и т.п., либо набрал баллы как клип/трек
    //   video   — длинный ролик, обзор, стрим, подкаст… — не ищем, пока вы не нажмёте «Это музыка»
    //   unknown — не поймёшь: ищем текст в LRCLIB по обычным правилам, но songrec (запись звука) не включаем
    function classify() {
        const t = rawTitle.toLowerCase(), a = rawArtist.toLowerCase(), u = trackUrl.toLowerCase()
        const browser = /firefox|chrom|brave|vivaldi|opera|zen|librewolf|edge|yandex|floorp|waterfox/.test(who)

        if (/^(advertisement|реклама|рекламное объявление|ad:|ad -)/.test(t)
            || /^spotify:ad:|open\.spotify\.com\/ad|doubleclick|googleads|\/pagead\/|[?&]adformat=/.test(u))
            return { kind: "ad", why: "заголовок/ссылка рекламы" }

        if (/youtube\.com\/shorts\//.test(u)) return { kind: "video", why: "YouTube Shorts" }

        const loc = localMap[locKey]
        if (memCache[curKey] || overrides[curKey] || (loc && (loc.file || loc.music)))
            return { kind: "music", why: "уже известен" }

        if (browser && trackLen > 0 && trackLen <= adMaxLen)
            return { kind: "ad", why: "ролик короче " + adMaxLen + " с" }

        if (!browser && who.trim() !== "") return { kind: "music", why: "нативный плеер: " + who.trim() }
        if (/music\.youtube\.com|soundcloud\.com|bandcamp\.com|music\.yandex|music\.apple|deezer\.com|tidal\.com|open\.spotify\.com/.test(u))
            return { kind: "music", why: "музыкальный сервис" }

        let sc = 0
        const why = []
        function add(n, r) { sc += n; why.push((n > 0 ? "+" : "") + n + " " + r) }
        if (/\s-\s*topic\s*$/.test(a)) add(3, "канал Topic")
        if (rawAlbum) add(1, "есть альбом")
        if (/^.+?(?:\s*[-–—•]\s+|\s*\|\s*).+$/.test(rawTitle)) add(1, "«Артист - Название»")
        if (a && norm(rawTitle).indexOf(norm(rawArtist)) >= 0 && norm(rawArtist).length >= 2) add(1, "артист упомянут в названии")
        if (/official\s*(audio|video|music|lyric)|lyric(s)?\s*video|клип|премьера|\b(feat|ft)\.?\s|\(audio\)|\[audio\]/.test(t)) add(1, "метки клипа")
        if (/slowed|sped\s*up|speed\s*up|nightcore|reverb|8d audio|bass boosted/.test(t)) add(1, "ремикс/слоуд")
        if (trackLen >= 100 && trackLen <= 480) add(1, "длина как у песни")
        if (trackLen > 0 && trackLen < 80) add(-1, "короткий")
        if (trackLen > 600) add(-2, "длинный")
        if (trackLen > 1200) add(-2, "очень длинный")
        // эмодзи в названии (😭💀🔥…) — признак обычного видео; музыкальные 🎵🎶🎧🎤🎸 не считаются
        if (/[\u{1F300}-\u{1FAFF}]/u.test(rawTitle.replace(/[\u{1F3B5}\u{1F3B6}\u{1F3A7}\u{1F3A4}\u{1F3B8}]/gu, ""))) add(-1, "эмодзи в названии")
        if (/обзор|стрим|stream|podcast|подкаст|tutorial|гайд|урок|walkthrough|прохождени|gameplay|геймплей|trailer|трейлер|review|interview|интервью|новости|\bnews\b|vlog|влог|reaction|реакци|подборка|compilation|#shorts|\d+\s*(час|hour)/.test(t))
            add(-3, "не похоже на песню по названию")

        const kind = sc >= 2 ? "music" : sc <= -1 ? "video" : "unknown"
        return { kind: kind, why: "баллы " + sc + " (" + why.join(", ") + ")" }
    }

    // «Это музыка»: запоминаем навсегда для этого трека и ищем текст
    // Дописывает поля в запись трека в local.json, не затирая остальные (file, no, music, bad, hidden)
    function setLoc(patch) {
        localMap[locKey] = Object.assign({}, localMap[locKey] || {}, patch)
        saveLocal()
    }

    // пользователь нажал "это музыка": запоминаем и ищем текст
    function markMusic() {
        setLoc({ music: true, hidden: false })
        startLookup()
    }

    // «Не та песня»: этот текст больше не подставляем для этого трека; убираем его, дальше — ручной поиск (открывает панель)
    function wrongSong() {
        if (status !== "found") return
        const m = memMeta[curKey] || {}
        const loc = localMap[locKey] || {}
        const patch = {}
        if (m.file) {
            const no = (loc.no || []).slice()
            if (no.indexOf(m.file) < 0) no.push(m.file)
            patch.no = no
            patch.file = undefined
        }
        if (m.id) {
            const bad = (loc.bad || []).slice()
            if (bad.indexOf(m.id) < 0) bad.push(m.id)
            patch.bad = bad
        }
        setLoc(patch)
        delete memCache[curKey]
        delete memMeta[curKey]
        if (overrides[curKey]) { delete overrides[curKey]; saveOverrides() }
        // автоподбор не запускаем: текст убираем, дальше человек сам ищет в ручном поиске
        gen++
        lines = []
        candidates = []
        suggestion = null
        notFoundFlash = false
        status = "notfound"
    }

    // «Закрыть текст для этой песни»: запоминаем навсегда, поиск не запускаем
    function hideForTrack() {
        setLoc({ hidden: true })
        gen++                       // обрываем идущий поиск / распознавание
        lines = []
        candidates = []
        suggestion = null
        notFoundFlash = false
        status = "hidden"
    }

    // вернуть скрытый текст
    function unhide() {
        setLoc({ hidden: false })
        startLookup()
    }

    // ==================== Локальная база ====================
    // список файлов локальной базы читаем через ls папки dbDir
    property bool dbAgain: false
    // обновить список .lrc в базе, потом вызвать cb
    function refreshDb(cb) {
        dbCb = cb
        // процесс уже идёт (и мог успеть отдать вывод прошлому запросу) — после выхода запустим ещё раз, иначе поиск повис бы
        if (dirProc.running) dbAgain = true
        else dirProc.running = true
    }

    // ls папки базы: каждый .lrc разбираем на артиста и название
    Process {
        id: dirProc
        command: ["sh", "-c", "mkdir -p \"$1\"; ls -1 \"$1\" 2>/dev/null", "sh", root.dbDir]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                text.split("\n").forEach(function(n) {
                    if (!/\.lrc$/i.test(n)) return
                    const raw = n.replace(/\.lrc$/i, "")
                    const m = raw.match(/^(.+?)\s+[-–—]\s+(.+)$/)
                    out.push({ file: n, raw: raw, base: root.norm(raw),
                               track: root.norm(m ? m[2] : raw), artist: m ? root.norm(m[1]) : "" })
                })
                root.dbFiles = out
                const cb = root.dbCb
                root.dbCb = null
                if (cb) cb()
            }
        }
        onExited: if (root.dbAgain) { root.dbAgain = false; if (root.dbCb) dirProc.running = true }
    }

    // чтение файла из базы (по одному, очередью)
    // файлы базы читаем по одному через очередь (cat)
    property var catQueue: []
    property var catCur: null
    // поставить файл в очередь на чтение
    function readLocal(file, cb) {
        catQueue.push({ file: file, cb: cb })
        pumpCat()
    }
    // запустить следующий cat, если никто не занят
    function pumpCat() {
        if (catProc.running || catCur !== null || catQueue.length === 0) return
        catCur = catQueue.shift()
        catProc.command = ["sh", "-c", "cat \"$1\" 2>/dev/null", "sh", dbDir + "/" + catCur.file]
        catProc.running = true
    }

    // отдаёт содержимое файла колбэку и берёт следующий из очереди
    Process {
        id: catProc
        stdout: StdioCollector {
            onStreamFinished: {
                const c = root.catCur
                root.catCur = null
                if (c) c.cb(text)
                root.pumpCat()
            }
        }
        onExited: root.pumpCat()
    }

    // есть ли в базе файл с таким именем
    function hasFile(f) {
        for (let i = 0; i < dbFiles.length; i++) if (dbFiles[i].file === f) return true
        return false
    }

    // Самый похожий файл базы (кроме уже отклонённых для этого трека)
    function findLocal() {
        const vars = buildVariants()
        const no = (localMap[locKey] && localMap[locKey].no) || []
        let best = null
        for (let i = 0; i < dbFiles.length; i++) {
            const f = dbFiles[i]
            if (no.indexOf(f.file) >= 0) continue
            let s = 0
            for (let k = 0; k < vars.length; k++) {
                const v = vars[k]
                let sc = Math.max(sim(f.track, v.track), sim(f.base, v.track))
                if (v.artist) sc = Math.max(sc, sim(f.base, v.artist + " " + v.track))
                // то же название, но артист явно другой — без вопроса не берём
                if (f.artist && v.artist && artScore(f.artist, v) < 0.4) sc *= (v.strict ? 0.4 : 0.7)   // Spotify: артист точно известен — чужого не предлагаем даже с вопросом
                s = Math.max(s, sc)
            }
            if (!best || s > best.name) best = { file: f.file, title: f.raw, name: s }
        }
        if (debug && best) console.warn("[Lyrics] локальная база:", best.title, "name=" + best.name.toFixed(2))
        return best && best.name >= suggestName ? best : null
    }

    // читает файл из базы и ставит текст; если файл битый - зовёт onFail
    function useLocal(file, g, onFail) {
        readLocal(file, function(text) {
            if (g !== gen) return
            const L = parseLrc(text)
            if (L.length === 0) { onFail(); return }
            lines = L
            status = "found"
            memCache[curKey] = L
            memMeta[curKey] = { file: file }
        })
    }

    // запоминает, что этот файл для этого трека не подходит
    function rejectLocal(file) {
        const cur = localMap[locKey] || {}
        const no = (cur.no || []).slice()
        if (no.indexOf(file) < 0) no.push(file)
        setLoc({ no: no, file: cur.file === file ? undefined : cur.file })
    }

    // «Да» — это оно: подставляем и запоминаем, в следующий раз без вопроса
    function confirmYes() {
        const s = suggestion
        if (status !== "confirm" || !s) return
        const g = gen
        suggestion = null
        status = "searching"
        setLoc({ file: s.file })
        useLocal(s.file, g, function() { rejectLocal(s.file); suggestOrNetwork(g) })
    }

    // «Нет» — запоминаем отказ и ищем дальше (следующий похожий файл или LRCLIB)
    function confirmNo() {
        const s = suggestion
        if (status !== "confirm" || !s) return
        suggestion = null
        status = "searching"
        rejectLocal(s.file)
        suggestOrNetwork(gen)
    }

    // ==================== Поиск ====================
    // главная точка входа: сбрасывает состояние, определяет что играет (реклама / видео / музыка) и запускает цепочку поиска
    function startLookup(noRec) {
        gen++
        recTried = noRec === true         // отложенный повтор не гоняет songrec второй раз
        notFoundFlash = false
        if (rawTitle !== lkTitle || rawArtist !== lkArtist) { candidates = []; manualState = "idle"; manualSeq++ }
        suggestion = null
        netFail = false
        pos = player ? player.position : 0
        lkTitle = rawTitle
        lkArtist = rawArtist
        // lines очищаем только когда текст реально меняется — иначе панель «складывается» и тут же раскладывается обратно
        if (!rawTitle) { lines = []; status = "idle"; return }
        curKey = norm(rawArtist) + "|" + norm(rawTitle) + "|" + Math.round(trackLen)
        locKey = norm(rawArtist) + "|" + norm(rawTitle)
        if (localMap[locKey] && localMap[locKey].hidden) { lines = []; status = "hidden"; return }   // «закрыть текст для этой песни»
        const k = classify()
        kind = k.kind
        if (debug) console.warn("[Lyrics] kind:", k.kind, "—", k.why, "|", rawArtist, "-", rawTitle, "|", Math.round(trackLen) + "с", trackUrl)
        if (k.kind === "ad") { lines = []; status = "ad"; return }
        if (k.kind === "video" && skipVideos) { lines = []; status = "video"; return }
        if (memCache[curKey]) { if (lines !== memCache[curKey]) lines = memCache[curKey]; status = "found"; return }
        lines = []
        status = "searching"
        const g = gen
        // сторож на весь поиск, а не только на сеть: если застрянет чтение базы — через 12 с перезапустимся
        watchGen = gen
        watchdog.restart()
        refreshDb(function() { if (g === gen) lookupLocal(g) })
    }

    // 1) трек уже привязан к файлу локальной базы → ставим сами
    function lookupLocal(g) {
        const loc = localMap[locKey]
        if (loc && loc.file && hasFile(loc.file)) {
            useLocal(loc.file, g, function() { lookupOverride(g) })
            return
        }
        lookupOverride(g)
    }

    // 2) ручной выбор из LRCLIB, сделанный раньше
    function lookupOverride(g) {
        if (!overrides[curKey]) { suggestOrNetwork(g); return }
        http("https://lrclib.net/api/get/" + overrides[curKey].id, function(r) {
            if (g !== gen) return
            if (!r || !apply(r, true)) suggestOrNetwork(g)
        })
    }

    // 3) в локальной базе есть похожее → спрашиваем; иначе обычный поиск в LRCLIB
    function suggestOrNetwork(g) {
        if (g !== gen) return
        const c = findLocal()
        if (c) {
            if (c.name >= exactName) {
                useLocal(c.file, g, function() { rejectLocal(c.file); suggestOrNetwork(g) })
                return
            }
            suggestion = { file: c.file, title: c.title }
            status = "confirm"
            return
        }
        runQueries(0, g, buildQueries(buildVariants()), null)
    }

    // гоняет запросы по очереди и копит лучшего кандидата; останавливается когда нашёлся достаточно хороший
    function runQueries(i, g, qs, best) {
        if (g !== gen) return
        if (i >= qs.length || (best && best.score >= goodScore && best.name >= minName)) { finish(g, best); return }
        const q = qs[i]
        const bad = (localMap[locKey] && localMap[locKey].bad) || []     // варианты, отклонённые кнопкой «Не та песня»
        http(q.url, function(res) {
            if (g !== gen) return
            let b = best
            const arr = Array.isArray(res) ? res : (res && res.id ? [res] : [])    // /api/get отвечает одним объектом, /api/search — массивом
            const strict = q.v.strict && q.v.artist
            for (let k = 0; k < arr.length; k++) {
                const c = arr[k]
                if (c.instrumental || !c.syncedLyrics || bad.indexOf(c.id) >= 0) continue
                const r = rate(c, q.v)
                if (strict && r.art < minArtist) {          // то же название, но другой артист — это не наша песня
                    if (debug && r.name >= minName) console.warn("[Lyrics] другой артист, пропуск:", c.artistName, "-", c.trackName, "art=" + r.art.toFixed(2))
                    continue
                }
                if (!b || r.score > b.score) b = { rec: c, score: r.score, name: r.name }
            }
            runQueries(i + 1, g, qs, b)
        })
    }

    // ставит "не найден": для музыки подсвечивает в баре на 8 с и один раз пробует ещё через 4 с
    function setNotFound() {
        status = "notfound"
        notFoundFlash = (kind === "music")      // для «неясно» тихо молчим, чтобы бар не мигал на обычных видео
        if (notFoundFlash) flashTimer.restart()
        // на ютубе после смены трека метаданные / сеть иногда «доезжают» позже — один раз пробуем ещё через пару секунд
        if (!lateTried && (kind === "music" || kind === "unknown")) { lateTried = true; lateGen = gen; lateTimer.restart() }
    }

    // отложенный повтор после "не найден"
    property int lateGen: -1
    Timer {
        id: lateTimer
        interval: 4000
        onTriggered: if (root.lateGen === root.gen && root.status === "notfound") root.startLookup(true)
    }

    // через 8 с гасим подсветку "не найден"
    Timer { id: flashTimer; interval: 8000; onTriggered: root.notFoundFlash = false }

    // итог поиска: берём лучшего если он достаточно хорош, иначе повтор после сбоя сети, потом songrec, потом "не найден"
    function finish(g, best) {
        if (g !== gen) return
        if (debug) console.log("[Lyrics]", curKey, best
            ? "лучший: " + best.rec.artistName + " - " + best.rec.trackName + " (" + best.rec.duration + "с) score=" + best.score.toFixed(2) + " name=" + best.name.toFixed(2)
            : "кандидатов с синхронным текстом нет", recTried ? "[после songrec]" : "")
        const needName = kind === "unknown" ? Math.max(minName, 0.85) : minName   // «неясно» — берём текст только при очень похожем названии
        if (best && best.score >= minScore && best.name >= needName && apply(best.rec, true)) return
        // пусто из-за сетевого сбоя — через пару секунд пробуем ещё раз (один раз), а не объявляем «не найден»
        if (!best && netFail && !retried) { retried = true; retryGen = g; retryTimer.restart(); return }
        if (!recTried) { recTried = true; if (kind === "music") { recognize(g); return } }
        setNotFound()
    }

    // ==================== Распознавание по звуку (songrec) ====================
    // songrec: пишем 10 с звука и распознаём; recGen / recRunGen нужны чтобы не перепутать записи разных треков
    property int recGen: 0
    property int recRunGen: -1       // для какого поиска запущена текущая запись
    property bool recAgain: false
    // запускает запись и распознавание (если прошлая запись ещё идёт - сначала гасим её)
    function recognize(g) {
        status = "recognizing"
        recGen = g
        // запись от прошлого трека ещё идёт — останавливаем и стартуем заново, когда она выйдет
        if (recProc.running) { recAgain = true; recProc.running = false; return }
        recRunGen = g
        recProc.running = true
    }

    Process {
        id: recProc
        // 10 секунд системного звука → songrec. timeout -s INT, чтобы parec дописал WAV-заголовок.
        command: ["sh", "-c",
            "f=\"${XDG_RUNTIME_DIR:-/tmp}/qs-lyrics-$$.wav\"; " +
            "timeout -s INT 10 parec -d @DEFAULT_MONITOR@ --rate=16000 --channels=1 --file-format=wav \"$f\" 2>/dev/null; " +
            "songrec audio-file-to-recognized-song \"$f\" 2>/dev/null; rm -f \"$f\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const g = root.recRunGen
                if (g !== root.gen) return           // результат записи прошлого трека — выбрасываем
                let j = null
                try { j = JSON.parse(text) } catch (e) {}
                const t = j && j.track ? j.track : null
                if (root.debug) console.log("[Lyrics] songrec:", t ? t.subtitle + " - " + t.title : "не опознал")
                if (!t || !t.title) { root.setNotFound(); return }
                root.status = "searching"
                root.runQueries(0, g, root.buildQueries([{ artist: root.norm(t.subtitle), track: root.norm(t.title), artists: root.splitArtists(t.subtitle), strict: root.spotify, exact: null }]), null)
            }
        }
        onExited: if (root.recAgain) {
            root.recAgain = false
            if (root.status === "recognizing" && root.recGen === root.gen) { root.recRunGen = root.recGen; recProc.running = true }
        }
    }

    // ==================== Ручной выбор (обычный поиск) ====================
    // manualState: idle | busy | empty | error — чтобы панель показывала «ищу…» / «ничего не найдено» / «нет связи»
    property string manualState: "idle"
    property int manualSeq: 0

    // Что подставить в строку поиска: «Артист - Название» из заголовка, а если в нём нет артиста — канал + заголовок
    function manualPrefill() {
        const t = rawTitle
            .replace(/[\(\[][^\)\]]*(official|video|audio|lyric|clip|клип|hd|hq|4k|remaster)[^\)\]]*[\)\]]/ig, " ")
            .replace(/\s+/g, " ").trim()
        const a = rawArtist.replace(/\s*[-–—]\s*topic\s*$/i, "").replace(/vevo$/i, "").trim()
        return (/\s[-–—|•]\s/.test(t) || !a ? t : a + " " + t).trim()
    }

    // GET без сторожа основного поиска: ручной поиск живёт сам по себе
    function manualGet(url, cb) {
        const x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return
            let r = null
            if (x.status === 200) { try { r = JSON.parse(x.responseText) } catch (e) {} }
            cb(r)
        }
        x.open("GET", url)
        x.setRequestHeader("Lrclib-Client", "quickshell-lyrics")
        x.send()
    }

    // сторож ручного поиска: 10 с нет ответа - показываем ошибку
    Timer {
        id: manualWatch
        interval: 10000
        onTriggered: if (root.manualState === "busy") { root.manualSeq++; root.manualState = "error" }
    }

    // Как в обычном поиске: что напечатали — то и ищем (без чистки и без транслита), результаты в порядке выдачи LRCLIB.
    // Запись «Артист - Название» дополнительно ищется по полям (в обе стороны), выдачи склеиваются без повторов.
    function searchManual(q) {
        q = String(q || "").replace(/\s+/g, " ").trim()
        const seq = ++manualSeq
        manualWatch.stop()
        if (q.length < 2) { candidates = []; manualState = "idle"; return }
        manualState = "busy"
        manualWatch.start()

        const base = "https://lrclib.net/api/search?", enc = encodeURIComponent, urls = []
        const m = q.match(/^(.+?)\s+[-–—]\s+(.+)$/)
        if (m) {
            urls.push(base + "artist_name=" + enc(m[1]) + "&track_name=" + enc(m[2]))
            urls.push(base + "artist_name=" + enc(m[2]) + "&track_name=" + enc(m[1]))
        }
        urls.push(base + "q=" + enc(q))

        const got = new Array(urls.length)
        let left = urls.length, failed = 0
        urls.forEach(function(u, i) {
            manualGet(u, function(res) {
                if (seq !== manualSeq) return          // пока ждали, запрос поменялся
                if (res === null) { failed++; got[i] = [] } else got[i] = res
                if (--left > 0) return
                manualWatch.stop()
                const seen = {}, out = []
                got.forEach(function(arr) {
                    arr.forEach(function(c) {
                        if (!c || c.instrumental || !c.syncedLyrics || seen[c.id]) return
                        seen[c.id] = true
                        out.push({ id: c.id, title: c.trackName, artist: c.artistName, duration: c.duration, rec: c,
                                   near: trackLen > 0 && c.duration > 0 && Math.abs(c.duration - trackLen) <= 3 })
                    })
                })
                if (out.length === 0 && failed === urls.length) { candidates = []; manualState = "error"; return }
                candidates = out.slice(0, 30)
                manualState = out.length ? "idle" : "empty"
            })
        })
    }

    // выбор варианта из ручного поиска: подставляем и запоминаем выбор на диске
    function pick(c) {
        if (!c || !apply(c.rec, true)) return
        overrides[curKey] = { id: c.id }
        saveOverrides()
        const loc = localMap[locKey] || {}
        if (loc.file || loc.hidden) setLoc({ file: undefined, hidden: false })
    }

    // пишет overrides.json (ручные выборы) в ~/.cache/qs-lyrics
    function saveOverrides() {
        if (writeProc.running) return
        writeProc.command = ["sh", "-c",
            "d=\"$HOME/.cache/qs-lyrics\"; mkdir -p \"$d\"; printf '%s' \"$1\" > \"$d/overrides.json\"",
            "sh", JSON.stringify(overrides)]
        writeProc.running = true
    }

    Process { id: writeProc }

    // то же для local.json (привязки к файлам базы); если запись ещё идёт - запомним и повторим
    property bool localDirty: false
    function saveLocal() {
        if (writeLocalProc.running) { localDirty = true; return }
        localDirty = false
        writeLocalProc.command = ["sh", "-c",
            "d=\"$HOME/.cache/qs-lyrics\"; mkdir -p \"$d\"; printf '%s' \"$1\" > \"$d/local.json\"",
            "sh", JSON.stringify(localMap)]
        writeLocalProc.running = true
    }

    Process { id: writeLocalProc; onExited: if (root.localDirty) root.saveLocal() }

    // при старте читаем сохранённое с диска: привязки к базе и ручные выборы
    Process {
        id: readLocalProc
        command: ["sh", "-c", "cat \"$HOME/.cache/qs-lyrics/local.json\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.localMap = JSON.parse(text) } catch (e) {} }
        }
    }

    Process {
        id: readProc
        command: ["sh", "-c", "cat \"$HOME/.cache/qs-lyrics/overrides.json\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.overrides = JSON.parse(text) } catch (e) {} }
        }
    }

    // ==================== Привязка к плееру ====================
    // Метаданные в браузере прилетают по частям — ждём, пока осядут
    Timer {
        id: debounce
        interval: 600
        onTriggered: {
            root.retried = false
            root.lateTried = false
            // метаданные «моргнули» (длина / ссылка поменялись), а трек тот же и текст уже есть — ничего не трогаем
            if (root.status === "found" && root.lines.length > 0 && root.rawTitle === root.lkTitle && root.rawArtist === root.lkArtist) return
            root.startLookup()
        }
    }

    // Трек сменился → сразу убираем текст прошлого трека (не ждём, пока метаданные осядут) и ждём debounce
    function trackTouched() {
        debounce.restart()
        // пустой заголовок — это обычно мигание метаданных, а не новый трек: текст не трогаем
        if (lines.length > 0 && rawTitle !== "" && (rawTitle !== lkTitle || rawArtist !== lkArtist)) { lines = []; status = "searching" }
    }
    // любое изменение метаданных идёт через debounce
    onRawTitleChanged: trackTouched()
    onRawArtistChanged: trackTouched()
    onTrackLenChanged: debounce.restart()
    onTrackUrlChanged: debounce.restart()

    // позиция плеера обновляется 20 раз в секунду, пока есть текст
    Timer {
        interval: 50
        repeat: true
        running: root.lines.length > 0 && root.player !== null
        onTriggered: root.pos = root.player.position
    }

    // на старте читаем сохранённое и запускаем первый поиск
    Component.onCompleted: { readProc.running = true; readLocalProc.running = true; debounce.start() }
}
