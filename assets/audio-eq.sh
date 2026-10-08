#!/bin/bash
# зачем это: чтобы вся музыка в системе шла через один общий эквалайзер,
# а не крутить эквалайзер в каждом плеере отдельно. Скрипт поднимает виртуальный
# выход "Эквалайзер" (PipeWire filter-chain на 10 полос), ловит потоки музыкальных
# плееров и переводит их на него, а остальной звук (звонки, уведомления) идёт мимо.
# Его дёргает панель эквалайзера в шелле: start / apply / select.
# Ниже полное описание команд.
#
# audio-eq.sh - системный 10-полосный эквалайзер на PipeWire filter-chain.
#
#   audio-eq.sh start [устройство] g1 ... g10   поднять виртуальный выход «Эквалайзер» и вести его звук на устройство
#                                               (имя узла PipeWire, пусто = текущий выход по умолчанию)
#   audio-eq.sh apply g1 ... g10                поменять усиление полос на лету
#   audio-eq.sh select <устройство>             сменить устройство вывода
#   audio-eq.sh debug                           показать, какие потоки считаются музыкой и почему
#   audio-eq.sh target                          напечатать устройство, куда сейчас направлен эквалайзер
#   audio-eq.sh load                            напечатать сохранённые усиления
#
# Выходом по умолчанию эквалайзер не становится: через него идёт только музыка (потоки MPRIS-плееров,
# потоки с ролью Music и приложения из файла $XDG_STATE_HOME/audio-eq/music-apps, по регулярке в строке).
# Всё остальное играет мимо. Работает, пока жив процесс (и шелл, из которого он запущен),
# при остановке потоки возвращаются на обычный выход. Усиление в дБ, полосы 31 62 125 250 500 1k 2k 4k 8k 16k Гц.
# Нужны pipewire, pipewire-pulse (pactl), pw-cli; желательно setpriv, busctl или playerctl.
# Коды выхода start: 0 штатная остановка, 1 ошибка запуска, 3 уже запущен.

# чтобы awk / sort / pactl не зависели от локали (иначе числа бывают с запятой)
export LC_ALL=C

# конфиг для pipewire, SINK - имя виртуального выхода, FREQS - частоты полос
CONF=/tmp/quickshell-audio-eq.conf
SINK=effect_input.audio_eq
FREQS=(31 62 125 250 500 1000 2000 4000 8000 16000)

# что помним между запусками: усиления, устройство, pid, список музыкальных приложений
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/audio-eq"
STATE="$STATE_DIR/gains"
TARGET_FILE="$STATE_DIR/target"
PID_FILE="$STATE_DIR/pid"
MUSIC_FILE="$STATE_DIR/music-apps"

# разбор аргументов: у start устройство необязательное (если первый аргумент не число - это имя устройства)
cmd=$1; [ $# -gt 0 ] && shift
arg=""
case "$cmd" in
    start)
        if [ $# -gt 0 ] && ! [[ "$1" =~ ^-?[0-9.]+$ ]]; then arg=$1; shift; fi
        ;;
    select)
        arg=$1
        [ $# -gt 0 ] && shift
        ;;
esac
# всё что осталось - усиления полос
gains=("$@")

# приводит усиления к числам и ограничивает ±24 дБ, чтобы мусор не ломал конфиг фильтра
normalize_gains() {
    [ "${#gains[@]}" -gt 0 ] || return 0
    local out
    out=$(printf '%s\n' "${gains[@]}" | awk '{ v = $1 + 0; if (v > 24) v = 24; if (v < -24) v = -24; printf "%.1f ", v }')
    read -ra gains <<< "$out"
}
normalize_gains

# усиление i-й полосы с одним знаком после запятой, по умолчанию 0
g() {
    printf '%.1f' "${gains[$1]:-0}"
}

# жив ли наш скрипт: PID из файла должен принадлежать процессу с audio-eq в командной строке
eq_running() {
    local p
    p=$(cat "$PID_FILE" 2>/dev/null)
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'audio-eq'
}

# с setpriv дочерний pipewire умирает вместе с нами, даже если нас убили
if command -v setpriv >/dev/null 2>&1; then PW_RUN=(setpriv --pdeathsig TERM pipewire)
else PW_RUN=(pipewire); fi

# убивает осиротевшие pipewire от прошлых запусков с нашим конфигом
kill_orphans() {
    pkill -TERM -fx "pipewire -c $CONF" 2>/dev/null
}

# запоминает текущие усиления на диск
save_state() {
    [ "${#gains[@]}" -gt 0 ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null && echo "${gains[*]}" > "$STATE" 2>/dev/null
}

HEADROOM=1.0
# считает множитель предусилителя: берёт АЧХ всей цепочки биквадов (Q=1, 48 кГц) и опускает уровень
# ровно на её максимальный подъём, чтобы не было клиппинга. HEADROOM - какую долю пика компенсировать
premult() {
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do echo "${FREQS[$i]} $(g "$i")"; done | awk -v hr="$HEADROOM" '
        { f[NR] = $1; gn[NR] = $2 }
        END {
            pi = 3.14159265358979; fs = 48000; Q = 1.0; mx = 0
            for (k = 0; k <= 400; k++) {
                w = 2 * pi * 20 * (1000 ^ (k / 400)) / fs
                db = 0
                for (i = 1; i <= NR; i++) {
                    A = 10 ^ (gn[i] / 40); w0 = 2 * pi * f[i] / fs
                    c = cos(w0); al = sin(w0) / (2 * Q); sA = 2 * sqrt(A) * al
                    if (i == 1) {
                        b0 = A * ((A + 1) - (A - 1) * c + sA); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - sA)
                        a0 = (A + 1) + (A - 1) * c + sA;       a1 = -2 * ((A - 1) + (A + 1) * c);    a2 = (A + 1) + (A - 1) * c - sA
                    } else if (i == NR) {
                        b0 = A * ((A + 1) + (A - 1) * c + sA); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - sA)
                        a0 = (A + 1) - (A - 1) * c + sA;       a1 = 2 * ((A - 1) - (A + 1) * c);     a2 = (A + 1) - (A - 1) * c - sA
                    } else {
                        b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A
                        a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A
                    }
                    cw = cos(w); c2 = cos(2 * w)
                    num = b0*b0 + b1*b1 + b2*b2 + 2 * (b0*b1 + b1*b2) * cw + 2 * b0*b2 * c2
                    den = a0*a0 + a1*a1 + a2*a2 + 2 * (a0*a1 + a1*a2) * cw + 2 * a0*a2 * c2
                    db += 10 * log(num / den) / log(10)
                }
                if (db > mx) mx = db
            }
            printf "%.4f", 10 ^ (-hr * mx / 20)
        }'
}

# id узла виртуального выхода эквалайзера в PipeWire (пусто, если его нет)
node_id() {
    pw-cli ls Node 2>/dev/null | awk -v n="\"$SINK\"" '
        /^[ \t]*id [0-9]+,/ { id = $2; sub(",", "", id) }
        index($0, "node.name") && index($0, n) { print id; exit }'
}

# имя первого настоящего устройства вывода (не эффекта)
first_real_sink() {
    pactl list short sinks 2>/dev/null | awk '$2 !~ /^effect_/ {print $2; exit}'
}

# есть ли устройство вывода с именем $1
sink_exists() {
    pactl list short sinks 2>/dev/null | awk -v t="$1" '$2 == t { f = 1 } END { exit !f }'
}

# имена MPRIS-плееров на шине (spotify, firefox, vlc ...) строчными, по одному в строке
mpris_names() {
    {
        busctl --user list --no-legend 2>/dev/null | awk '{print $1}' | sed -n 's/^org\.mpris\.MediaPlayer2\.//p'
        playerctl -l 2>/dev/null
    } | sed 's/\.instance[0-9]*$//' | tr 'A-Z' 'a-z' | sort -u
}

# PID процессов, которым принадлежат MPRIS-имена
mpris_pids() {
    busctl --user list --no-legend 2>/dev/null | awk '$1 ~ /^org\.mpris\.MediaPlayer2\./ && $2 ~ /^[0-9]+$/ { print $2 }' | sort -u
}

# список потоков воспроизведения: id, sink, роль, приложение, бинарник, id приложения, узел, pid, имя потока
# (разделитель \037, чтобы пустые поля не терялись)
list_streams() {
    pactl list sink-inputs 2>/dev/null | awk '
        function val(l) { sub(/^[^=]*= "?/, "", l); sub(/"$/, "", l); return l }
        function flush() {
            if (id != "") printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", id, sink, role, app, bin, appid, node, spid, mname
        }
        /^Sink Input #/ { flush(); id = substr($3, 2); sink = role = app = bin = appid = node = spid = mname = ""; next }
        /^[ \t]+Sink: /                          { sink  = $2; next }
        /^[ \t]+media\.role = /                  { role  = val($0); next }
        /^[ \t]+media\.name = /                  { mname = val($0); next }
        /^[ \t]+application\.name = /            { app   = val($0); next }
        /^[ \t]+application\.process\.binary = / { bin   = val($0); next }
        /^[ \t]+application\.process\.id = /     { spid  = val($0); next }
        /^[ \t]+application\.id = /              { appid = val($0); next }
        /^[ \t]+node\.name = /                   { node  = val($0); next }
        END { flush() }'
}

# родитель процесса $1 (берёт ppid из /proc/PID/stat)
parent_of() {
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{ print $2 }'
}

# потоки, которые не получилось перенести (чтобы не писать об ошибке каждую секунду)
FAILED_IDS=" "
# раскладывает потоки: музыку (плееры по MPRIS, роль Music, music-apps) переводит на эквалайзер,
# остальное возвращает на обычный выход. AUDIO_EQ_DEBUG=1 печатает решение по каждому потоку
route_music() {
    local eq_idx mpris mpids extra id sink role app bin appid node spid mname hay music why p pl rx q i out
    eq_idx=$(pactl list short sinks 2>/dev/null | awk -v n="$SINK" '$2 == n { print $1; exit }')
    if [ -z "$eq_idx" ] && [ -z "$AUDIO_EQ_DEBUG" ]; then return 0; fi
    mpris=$(mpris_names)
    mpids=$(mpris_pids | tr '\n' ' ')
    extra=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$MUSIC_FILE" 2>/dev/null)

    if [ -n "$AUDIO_EQ_DEBUG" ]; then
        echo "виртуальный выход: ${eq_idx:-не найден (эквалайзер не запущен?)}"
        echo "MPRIS-плееры: ${mpris:-нет}" | tr '\n' ' '; echo
        echo "PID владельцев MPRIS: ${mpids:-нет}"
        echo "дополнительно из music-apps: ${extra:-нет}" | tr '\n' ' '; echo
        echo "потоки:"
    fi

    while IFS=$'\037' read -r id sink role app bin appid node spid mname; do
        [ -n "$id" ] || continue
        case "$node$app" in *effect_output*|*effect_input*|*audio_eq*) continue ;; esac

        hay=$(printf '%s %s %s %s' "$app" "$bin" "$appid" "$mname" | tr 'A-Z' 'a-z')
        music=0
        why=""
        if [ "$role" = "Music" ]; then music=1; why="роль Music"; fi

        if [ "$music" -eq 0 ]; then
            for p in $mpris; do
                pl=${p##*.}
                case "$hay" in *"$p"*) music=1; why="имя совпало с MPRIS-плеером «$p»"; break ;; esac
                if [ "${#pl}" -ge 3 ]; then
                    case "$hay" in *"$pl"*) music=1; why="имя совпало с MPRIS-плеером «$p»"; break ;; esac
                fi
            done
        fi

        if [ "$music" -eq 0 ] && [ -n "$mpids" ] && [ -n "$spid" ]; then
            q=$spid
            for i in 1 2 3 4 5 6; do
                { [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; } || break
                case " $mpids " in *" $q "*) music=1; why="процесс — потомок MPRIS-плеера (pid $q)"; break ;; esac
                q=$(parent_of "$q")
            done
        fi

        if [ "$music" -eq 0 ] && [ -n "$extra" ]; then
            while IFS= read -r rx; do
                [ -n "$rx" ] || continue
                if printf '%s' "$hay" | grep -qiE -- "$rx" 2>/dev/null; then music=1; why="music-apps: $rx"; break; fi
            done <<< "$extra"
        fi

        if [ -n "$AUDIO_EQ_DEBUG" ]; then
            printf '  #%s sink=%s app=«%s» bin=«%s» id=«%s» pid=%s имя=«%s» → %s%s\n' \
                "$id" "$sink" "$app" "$bin" "$appid" "${spid:--}" "$mname" \
                "$([ "$music" -eq 1 ] && echo 'МУЗЫКА' || echo 'не музыка')" "${why:+ ($why)}"
        fi
        [ -n "$eq_idx" ] || continue

        if [ "$music" -eq 1 ] && [ "$sink" != "$eq_idx" ]; then
            if ! out=$(pactl move-sink-input "$id" "$SINK" 2>&1); then
                case "$FAILED_IDS" in
                    *" $id "*) ;;
                    *) FAILED_IDS+="$id "; echo "audio-eq: не удалось перенести поток #$id («$app») на эквалайзер: $out" >&2 ;;
                esac
            fi
        elif [ "$music" -eq 0 ] && [ "$sink" = "$eq_idx" ]; then
            pactl move-sink-input "$id" @DEFAULT_SINK@ 2>/dev/null
        fi
    done < <(list_streams)
}

# возвращает все потоки с виртуального выхода на обычный (при остановке)
release_streams() {
    local eq_idx i
    eq_idx=$(pactl list short sinks 2>/dev/null | awk -v n="$SINK" '$2 == n { print $1; exit }')
    [ -n "$eq_idx" ] || return 0
    for i in $(pactl list short sink-inputs 2>/dev/null | awk -v e="$eq_idx" '$2 == e { print $1 }'); do
        pactl move-sink-input "$i" @DEFAULT_SINK@ 2>/dev/null
    done
}

# PID шелла (quickshell), из которого запущен скрипт: сначала среди предков, иначе единственный quickshell пользователя
owner_pid() {
    local q=$$ i comm
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        q=$(parent_of "$q")
        { [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; } || break
        comm=$(cat "/proc/$q/comm" 2>/dev/null)
        case "$comm" in *quickshell*|qs) echo "$q"; return ;; esac
    done
    local cand
    cand=$(pgrep -u "$(id -u)" -x quickshell 2>/dev/null)
    [ "$(printf '%s\n' "$cand" | grep -c .)" -eq 1 ] && echo "$cand"
}

# жив ли шелл: PID $1 существует и это всё ещё процесс с именем $2
owner_alive() {
    kill -0 "$1" 2>/dev/null && [ "$(cat "/proc/$1/comm" 2>/dev/null)" = "$2" ]
}

# фоновый сторож. Раз в секунду раскладывает потоки, проверяет шелл (пропал - шлёт SIGTERM основному
# процессу) и раз в две секунды целевое устройство (пропало - переключает на первое настоящее и шлёт SIGUSR1).
# $1 - PID основного процесса, $2 и $3 - PID и имя процесса шелла
watch_target() {
    local main=$1 owner=$2 ocomm=$3 t real n=0
    while kill -0 "$main" 2>/dev/null; do
        sleep 1
        if [ -n "$owner" ] && ! owner_alive "$owner" "$ocomm"; then
            echo "audio-eq: шелл (pid $owner) завершился, останавливаю эквалайзер" >&2
            kill -TERM "$main" 2>/dev/null
            return
        fi
        route_music
        n=$((n+1))
        [ $((n%2)) -eq 0 ] || continue
        t=$(cat "$TARGET_FILE" 2>/dev/null)
        [ -n "$t" ] || continue
        sink_exists "$t" && continue
        real=$(first_real_sink)
        [ -n "$real" ] || continue
        echo "audio-eq: устройство «$t» пропало, переключаюсь на «$real»" >&2
        echo "$real" > "$TARGET_FILE"
        pactl set-default-sink "$real" 2>/dev/null
        kill -USR1 "$main" 2>/dev/null
    done
}

# пишет конфиг PipeWire filter-chain в $CONF: по цепочке из 10 биквадов на канал плюс предусилитель
gen_config() {
    local nodes="" links="" ins="" outs="" ch i type tline="" pm
    pm=$(premult)

    for ch in L R; do
        nodes+="        { type = builtin name = pre${ch} label = linear control = { \"Mult\" = $pm \"Add\" = 0.0 } }"$'\n'
        links+="        { output = \"pre${ch}:Out\" input = \"eq${ch}_0:In\" }"$'\n'
        for i in 0 1 2 3 4 5 6 7 8 9; do
            if   [ "$i" -eq 0 ]; then type=bq_lowshelf
            elif [ "$i" -eq 9 ]; then type=bq_highshelf
            else type=bq_peaking; fi
            nodes+="        { type = builtin name = eq${ch}_$i label = $type control = { \"Freq\" = ${FREQS[$i]} \"Q\" = 1.0 \"Gain\" = $(g "$i") } }"$'\n'
            [ "$i" -lt 9 ] && links+="        { output = \"eq${ch}_$i:Out\" input = \"eq${ch}_$((i + 1)):In\" }"$'\n'
        done
        ins+="\"pre${ch}:In\" "
        outs+="\"eq${ch}_9:Out\" "
    done

    tline="        node.dont-fallback = true"
    [ -n "$prev" ] && tline+=$'\n'"        target.object = \"$prev\""

    cat > "$CONF" <<EOF
context.properties = {
  log.level = 2
}

context.spa-libs = {
  audio.convert.* = audioconvert/libspa-audioconvert
  support.*       = support/libspa-support
}

context.modules = [
  { name = libpipewire-module-rt
    args = { nice.level = -11 }
    flags = [ ifexists nofail ]
  }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "Эквалайзер"
      media.name       = "Эквалайзер"
      filter.graph = {
        nodes = [
$nodes        ]
        links = [
$links        ]
        inputs  = [ $ins]
        outputs = [ $outs]
      }
      audio.channels = 2
      audio.position = [ FL FR ]
      capture.props = {
        node.name   = "$SINK"
        media.class = Audio/Sink
      }
      playback.props = {
        node.name    = "effect_output.audio_eq"
        node.passive = true
$tline
      }
    }
  }
]
EOF
}

# главный диспетчер команд
case "$cmd" in
# start: поднимает эквалайзер и висит, пока жив (или пока не убьют / не закроется шелл)
start)
    mkdir -p "$STATE_DIR"
    if eq_running; then
        echo "audio-eq: уже запущен" >&2
        exit 3
    fi
    kill_orphans
    rm -f "$PID_FILE"

    prev=$arg
    [ -z "$prev" ] && prev=$(pactl get-default-sink 2>/dev/null)
    if [ -z "$prev" ] || [ "$prev" = "$SINK" ] || [[ "$prev" == effect_* ]]; then
        prev=$(first_real_sink)
    fi
    echo "$prev" > "$TARGET_FILE"; echo $$ > "$PID_FILE"
    save_state

    case "$(pactl get-default-sink 2>/dev/null)" in
        effect_*) [ -n "$prev" ] && pactl set-default-sink "$prev" 2>/dev/null ;;
    esac

    pid=""; watcher=""; retarget=0

    # штатная остановка: гасит сторожа, возвращает потоки на обычный выход, убивает pipewire и чистит файлы
    cleanup() {
        [ -n "$watcher" ] && kill "$watcher" 2>/dev/null
        release_streams
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        prev=$(cat "$TARGET_FILE" 2>/dev/null)
        case "$(pactl get-default-sink 2>/dev/null)" in
            effect_*) [ -n "$prev" ] && pactl set-default-sink "$prev" 2>/dev/null ;;
        esac
        rm -f "$PID_FILE" "$TARGET_FILE"
        exit "${1:-0}"
    }
    # TERM / INT / HUP - штатный выход; USR1 - просто перезапустить pipewire (при смене устройства)
    trap 'cleanup 0' TERM INT HUP
    trap 'retarget=1; [ -n "$pid" ] && kill "$pid" 2>/dev/null' USR1

    owner=$(owner_pid)
    ocomm=""
    [ -n "$owner" ] && ocomm=$(cat "/proc/$owner/comm" 2>/dev/null)
    [ -n "$owner" ] || echo "audio-eq: процесс шелла не найден — слежение за его падением отключено" >&2

    # сторож крутится в фоне
    watch_target "$$" "$owner" "$ocomm" &
    watcher=$!

    # основной цикл: поднимаем pipewire с конфигом, ждём пока появится виртуальный выход, раскладываем потоки
    # и ждём пока pipewire умрёт. После USR1 (сменили устройство) идём по кругу заново
    while :; do
        prev=$(cat "$TARGET_FILE" 2>/dev/null)
        if [ -n "$prev" ] && ! sink_exists "$prev"; then
            real=$(first_real_sink)
            if [ -n "$real" ]; then
                echo "audio-eq: устройство «$prev» недоступно, использую «$real»" >&2
                prev=$real
                echo "$prev" > "$TARGET_FILE"
            fi
        fi
        [ -r "$STATE" ] && read -ra gains < "$STATE"
        normalize_gains

        gen_config
        "${PW_RUN[@]}" -c "$CONF" &
        pid=$!

        for _ in $(seq 1 40); do
            [ -n "$(node_id)" ] && break
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done

        if [ -z "$(node_id)" ]; then
            if [ "$retarget" -eq 1 ]; then retarget=0; continue; fi
            echo "audio-eq: виртуальный выход не появился, эквалайзер не запущен" >&2
            cleanup 1
        fi

        route_music

        while kill -0 "$pid" 2>/dev/null; do
            wait "$pid"
        done

        if [ "$retarget" -eq 1 ]; then
            retarget=0
            continue
        fi
        break
    done
    cleanup 0
    ;;

# apply: поменять усиления на лету, без перезапуска (шлём новые значения в узел через pw-cli)
apply)
    save_state
    id=$(node_id)
    [ -z "$id" ] && exit 1
    pm=$(premult)
    params=" \"preL:Mult\" $pm \"preR:Mult\" $pm"
    for i in 0 1 2 3 4 5 6 7 8 9; do
        v=$(g "$i")
        params+=" \"eqL_$i:Gain\" $v \"eqR_$i:Gain\" $v"
    done
    pw-cli s "$id" Props "{ params = [ $params ] }" >/dev/null
    ;;

# select: сменить устройство вывода (если эквалайзер запущен - просим основной процесс перезапустить цепочку)
select)
    [ -z "$arg" ] && exit 2
    if eq_running; then
        mkdir -p "$STATE_DIR"
        echo "$arg" > "$TARGET_FILE"
        pactl set-default-sink "$arg" 2>/dev/null
        kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null
    else
        pactl set-default-sink "$arg"
    fi
    ;;

# target: куда сейчас направлен эквалайзер
target)
    if eq_running; then cat "$TARGET_FILE" 2>/dev/null; fi
    ;;

# debug: показать что запущено и какие потоки считаются музыкой
debug)
    owner=$(owner_pid)
    if eq_running; then echo "эквалайзер: запущен, устройство «$(cat "$TARGET_FILE" 2>/dev/null)»"
    else echo "эквалайзер: НЕ запущен"; fi
    echo "выход по умолчанию: $(pactl get-default-sink 2>/dev/null)"
    echo "шелл (слежение): ${owner:-не найден}"
    AUDIO_EQ_DEBUG=1 route_music
    ;;

# load: сохранённые усиления (или нули)
load)
    if [ -r "$STATE" ]; then cat "$STATE"; else echo "0 0 0 0 0 0 0 0 0 0"; fi
    ;;

*)
    echo "usage: $0 start [device] g1..g10 | apply g1..g10 | select <device> | target | load" >&2
    exit 2
    ;;
esac
