#!/usr/bin/env python3
# ------------------------------------------------------------------
# auto_lrc.py
#
# зачем это вообще: хотел чтобы караоке-текст в панели лирики шёл
# синхронно с песней, а тайминги вручную расставлять - это пипец как долго.
# Тут всё делает whisper: даёшь ему готовый текст песни + аудио (файл или
# ссылку на ютуб), он сам находит где какая строчка звучит и на выходе
# получается .lrc, который можно сразу кидать в LyricsPanel.
#
# запуск руками:
#   python3 auto_lrc.py lyrics.txt "https://youtu.be/..." -o turbo.lrc
#   python3 auto_lrc.py lyrics.txt song.mp3 --vocals
#
# ставить: pip install --user stable-ts yt-dlp  (+ demucs если нужен --vocals)
# окошко LrcGen.qml дёргает этот скрипт сам, ключи --ui и --progress для него
# ------------------------------------------------------------------
import argparse, glob, os, re
import shutil
import subprocess
import sys, tempfile


# сообщения скрипта на двух языках, какой - решает ключ --ui
MSG = {
 "ru": {
    "no_download": "yt-dlp не скачал аудио",
    "no_file": "Файл не найден: {p}",
    "no_vocals": "demucs не создал вокальную дорожку",
    "no_lines": "В {p} нет строк текста — проверьте файл.",
    "need_out": "С --transcribe укажите имя результата: -o turbo.lrc",
    "no_stable": "Не установлен stable-ts: pip install --user stable-ts",
    "loading": "Загружаю модель {m} (первый раз скачивается) …",
    "transcribing": "Распознаю слова по звуку …",
    "aligning": "Выравниваю текст по звуку …",
    "mismatch": "Внимание: сегментов {s}, строк {n} — беру текст из сегментов.",
    "tail": "Распознаю хвост после {t:.1f} с …",
    "tail_done": "Дописано строк из хвоста: {n}",
    "done": "Готово: {o} ({n} строк)",
 },
 "en": {
    "no_download": "yt-dlp did not download any audio",
    "no_file": "File not found: {p}",
    "no_vocals": "demucs did not produce a vocals track",
    "no_lines": "No lyrics lines in {p} — check the file.",
    "need_out": "With --transcribe, specify the output name: -o turbo.lrc",
    "no_stable": "stable-ts is not installed: pip install --user stable-ts",
    "loading": "Loading model {m} (downloaded on first use) …",
    "transcribing": "Recognizing words from the audio …",
    "aligning": "Aligning lyrics to the audio …",
    "mismatch": "Warning: {s} segments vs {n} lines — using text from the segments.",
    "tail": "Recognizing the ending after {t:.1f} s …",
    "tail_done": "Lines added from the ending: {n}",
    "done": "Done: {o} ({n} lines)",
 }
}
UI = "ru"
PROGRESS=False



# достаёт сообщение по ключу на нужном языке и подставляет значения
def m(key, **kw):
    return MSG.get(UI, MSG["ru"])[key].format(**kw)

# печатает метку этапа для окошка (только если включён --progress),
# по ней QML понимает на каком шаге мы сейчас
def stage(name):
    if PROGRESS :
        print("@@stage:"+name, flush=True)


# читает файл с текстом и чистит его: выкидывает пустые строки,
# заголовки типа [Припев] и превращает markdown-ссылки с Genius в обычный текст
def load_lines(path):
    res=[]
    with open(path, encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            if not line: continue
            if re.fullmatch(r"\[[^\]]*\]", line):
                continue
            line = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", line)
            line = line.strip()
            if line: res.append(line)
    return res



# секунды -> метка [мм:сс.xx] как в .lrc
def fmt(t):
    m = int(t // 60)
    s = t - m*60
    return f"[{m:02d}:{s:05.2f}]"


# запускает внешнюю команду (yt-dlp, demucs) и пишет в консоль что именно запускаем
def run(cmd):
    print("→", " ".join(cmd))
    subprocess.run(cmd,check=True)


# если source это ссылка - качаем звук через yt-dlp во временную папку,
# если файл - просто проверяем что он есть. Возвращает путь к аудио
def get_audio(src, tmp):
    if re.match(r"https?://", src):
        out = os.path.join(tmp, "audio.%(ext)s")
        run(["yt-dlp", "-x", "--audio-format", "wav", "--no-playlist", "-o", out, src])
        files = glob.glob(os.path.join(tmp,"audio.*"))
        if not files:
            sys.exit(m("no_download"))
        return files[0]
    if not os.path.isfile(src):
        sys.exit(m("no_file", p=src))
    return src


# отделяет голос от музыки через demucs, на жёстком бите whisper так
# выравнивает заметно точнее. Возвращает путь к vocals-дорожке
def separate_vocals(audio, tmp):
    run([sys.executable, "-m", "demucs", "--two-stems=vocals", "-o", os.path.join(tmp, "sep"), audio])
    found = glob.glob(os.path.join(tmp,"sep","*","*","vocals.*"))
    if not found:
        sys.exit(m("no_vocals"))
    return found[0]



# главная функция: разбирает аргументы, готовит аудио, гоняет whisper
# (выравнивание текста или распознавание с нуля) и пишет готовый .lrc
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lyrics")
    ap.add_argument("source", help="ссылка или аудиофайл")
    ap.add_argument("-o", "--out")
    ap.add_argument("--lang", default="ru")
    ap.add_argument("--model", default="medium")
    ap.add_argument("--vocals", action="store_true")
    ap.add_argument("--tail", action="store_true",
        help="после выравнивания распознать на слух всё, что звучит после последней строки текста")
    ap.add_argument("--transcribe", action="store_true",
        help="не использовать lyrics.txt (передайте вместо него '-'): слова распознаются по звуку")
    ap.add_argument("--ui", choices=sorted(MSG), default="ru", help="язык сообщений / message language")
    ap.add_argument("--progress", action="store_true", help="печатать метки этапов для GUI")
    a = ap.parse_args()
    global UI, PROGRESS
    UI, PROGRESS = a.ui, a.progress

    lines = [] if a.transcribe else load_lines(a.lyrics)
    if not lines and not a.transcribe:
        sys.exit(m("no_lines", p=a.lyrics))
    if a.transcribe and a.lyrics == "-" and not a.out:
        sys.exit(m("need_out"))
    out = a.out or os.path.splitext(a.lyrics)[0]+".lrc"

    # whisper импортируем тут а не сверху, чтобы без него скрипт
    # хотя бы нормально ругнулся а не падал трейсбеком
    try:
        import stable_whisper
    except ImportError:
        sys.exit(m("no_stable"))

    tmp = tempfile.mkdtemp(prefix="auto_lrc_")
    try:
        stage("audio")
        audio = get_audio(a.source, tmp)
        if a.vocals:
            stage("vocals")
            audio = separate_vocals(audio, tmp)

        stage("model")
        print(m("loading", m=a.model))
        model = stable_whisper.load_model(a.model)

        if a.transcribe:
            stage("transcribe")
            print(m("transcribing"))
            res = model.transcribe(audio, language=a.lang)
            pairs = [(s.start, s.text.strip()) for s in res.segments if s.text.strip()]
        else:
            stage("align")
            print(m("aligning"))
            result = model.align(audio, "\n".join(lines), language=a.lang, original_split=True)

            segs = result.segments
            if len(segs) != len(lines):
                print(m("mismatch", s=len(segs), n=len(lines)))
                pairs = [(s.start, s.text.strip()) for s in segs if s.text.strip()]
            else:
                pairs = [(s.start, lines[i]) for i,s in enumerate(segs)]

            # хвост: если после последней строки текста в песне ещё что-то поют
            if a.tail and segs:
                last = segs[-1].end
                stage("tail")
                print(m("tail", t=last))
                res = model.transcribe(audio, language=a.lang)
                extra = [(s.start, s.text.strip()) for s in res.segments
                           if s.start >= last-0.5 and s.text.strip()]
                print(m("tail_done", n=len(extra)))
                pairs += extra

        stage("save")
        with open(out, "w", encoding="utf-8") as f:
            for t, text in pairs:
                f.write(f"{fmt(t)}{text}\n")
        print(m("done", o=out, n=len(pairs)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
