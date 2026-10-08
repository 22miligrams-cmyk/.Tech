#!/usr/bin/env python3
# color.py
#
# Берёт обои и делает из них цветовую тему для Quickshell (бар, лаунчер, выбор обоев)
# и для рамок окон в Hyprland.
#
# Запуск:
#   color.py <путь_к_обоям>   применить тему из этих обоев + обновить кеш палитр
#   color.py                  только досчитать палитры для всех обоев из папки
#
# Как это работает, по шагам:
#   1. extract()       — уменьшаем картинку, сжимаем до пары десятков цветов, склеиваем похожие
#                        и выбираем 3 цвета палитры + один «живой» акцентный
#   2. build_theme()   — из них собираем bg / border / accent / subtext / secondary / text,
#                        следя за контрастом, чтобы всё читалось
#   3. пишем файлы и (если цвета поменялись) правим рамки в hyprland.lua + hyprctl reload
#
# Файлы (формат прежний, QML менять не нужно):
#   ~/.cache/quickshell/colors.json    тема, ОДНОЙ строкой — laun.qml читает файл построчно через SplitParser
#   ~/.cache/quickshell/palettes.json  { "<путь к обоям>": [цвет1, цвет2, цвет3], ... }
import colorsys
import fcntl
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image


# ======================= НАСТРОЙКИ =======================
WALLPAPER_DIR = os.environ.get("QS_WALLPAPERS", "/home/k2dein/Изображения/wallpapers")
CACHE_DIR = os.environ.get("QS_CACHE", os.path.expanduser("~/.cache/quickshell"))
HYPRLAND_CONF = os.environ.get("QS_HYPR_CONF", os.path.expanduser("~/.config/hypr/hyprland.lua"))

PALETTES_FILE = os.path.join(CACHE_DIR, "palettes.json")
COLORS_FILE = os.path.join(CACHE_DIR, "colors.json")
LOCK_FILE = os.path.join(CACHE_DIR, "color.lock")

ALGO_VERSION = 4        # при смене алгоритма старый кеш палитр пересчитается сам
SAMPLE_SIZE = 160       # обои уменьшаются до такого размера по большей стороне
QUANT_COLORS = 24       # на сколько цветов сжимается картинка перед анализом
MERGE_DIST = 34         # цвета ближе этого расстояния (RGB) считаются одним
BOTTOM_WEIGHT = 1.5     # вес нижней половины картинки (земля/трава обычно «главнее» неба)
GREEN_BONUS = 1.0       # >1.0 — предпочитать зелёный (раньше было 1.5); 1.0 — без предпочтений
TINT_BG = True          # красить фон панели в очень тёмный оттенок обоев (False — всегда #181825)

DEFAULT_PALETTE = ["#a3cef1", "#6893c7", "#3d5a80"]
DEFAULT_BG = "#181825"
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")


# ======================= ЦВЕТОВЫЕ УТИЛИТЫ =======================

# Зажимает число в диапазон [lo, hi]
def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))


# "#a3cef1" -> (163, 206, 241)
def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# (163, 206, 241) -> "#a3cef1" (значения округляются и зажимаются в 0..255)
def rgb_to_hex(rgb):
    return "#{:02x}{:02x}{:02x}".format(*[int(round(clamp(c, 0, 255))) for c in rgb])


# RGB (0..255) -> HSV (0..1)
def to_hsv(rgb):
    return colorsys.rgb_to_hsv(*[c / 255.0 for c in rgb])


# HSV (0..1) -> RGB (0..255); насыщенность и яркость зажимаются
def from_hsv(h, s, v):
    return tuple(c * 255.0 for c in colorsys.hsv_to_rgb(h, clamp(s), clamp(v)))


# RGB (0..255) -> HLS (0..1)
def to_hls(rgb):
    return colorsys.rgb_to_hls(*[c / 255.0 for c in rgb])


# HLS (0..1) -> RGB (0..255); светлота и насыщенность зажимаются
def from_hls(h, l, s):
    return tuple(c * 255.0 for c in colorsys.hls_to_rgb(h, clamp(l), clamp(s)))


# Расстояние между двумя цветами в RGB (обычная евклидова метрика)
def rgb_dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


# Расстояние между двумя оттенками (hue) с учётом того, что круг замкнут: 0.95 и 0.05 рядом
def hue_dist(h1, h2):
    d = abs(h1 - h2)
    return min(d, 1.0 - d)


# Относительная яркость цвета по WCAG (нужна для расчёта контраста)
def rel_lum(rgb):
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


# Коэффициент контраста двух цветов по WCAG (от 1 до 21)
def contrast(a, b):
    la, lb = rel_lum(a), rel_lum(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


# Двигает светлоту цвета, пока контраст с bg не дойдёт до ratio (оттенок и насыщенность сохраняются).
# lighten=True — осветляем, False — затемняем. Если упёрлись в край шкалы — отдаём что есть
def push_lightness(rgb, bg, ratio, lighten=True):
    h, l, s = to_hls(rgb)
    for _ in range(60):
        cur = from_hls(h, l, s)
        if contrast(cur, bg) >= ratio:
            return cur
        l += 0.015 if lighten else -0.015
        if l > 0.97 or l < 0.03:
            break
    return from_hls(h, clamp(l, 0.03, 0.97), s)


# ======================= ИЗВЛЕЧЕНИЕ ПАЛИТРЫ =======================

# Склеивает близкие цвета в один (среднее, взвешенное по количеству пикселей).
# clusters — список (rgb, вес), thr — порог расстояния
def merge_clusters(clusters, thr):
    out = []
    for rgb, w in sorted(clusters, key=lambda c: -c[1]):
        for k, (rgb2, w2) in enumerate(out):
            if rgb_dist(rgb, rgb2) < thr:
                tot = w + w2
                out[k] = (tuple((a * w2 + b * w) / tot for a, b in zip(rgb, rgb2)), tot)
                break
        else:
            out.append((rgb, w))
    return out


# Главная функция анализа обоев. Возвращает {'palette': [hex, hex, hex], 'accent': hex}.
# Если картинка не читается — отдаёт палитру по умолчанию, а не падает
def extract(path):
    fallback = {"palette": list(DEFAULT_PALETTE), "accent": DEFAULT_PALETTE[0]}
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            im.thumbnail((SAMPLE_SIZE, SAMPLE_SIZE), Image.LANCZOS)

        q = im.quantize(colors=QUANT_COLORS, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        pal = q.getpalette() or []
        w, h = q.size
        px = q.load()

        # считаем сколько пикселей каждого цвета (нижняя половина весит больше)
        counts = {}
        for y in range(h):
            wy = BOTTOM_WEIGHT if y > h // 2 else 1.0
            for x in range(w):
                i = px[x, y]
                counts[i] = counts.get(i, 0.0) + wy

        clusters = [((pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]), wgt) for i, wgt in counts.items()]
        clusters = merge_clusters(clusters, MERGE_DIST)

        items = []
        for rgb, wgt in clusters:
            hh, ss, vv = to_hsv(rgb)
            if GREEN_BONUS != 1.0 and 0.2 < hh < 0.45:
                wgt *= GREEN_BONUS
            items.append({"rgb": rgb, "w": wgt, "h": hh, "s": ss, "v": vv})

        # «пригодные» цвета: не почти чёрные, не пересвеченные и не серые
        usable = [c for c in items if c["s"] >= 0.12 and 0.12 <= c["v"] <= 0.98]
        if not usable:
            usable = [c for c in items if 0.12 <= c["v"] <= 0.98] or items
        if not usable:
            return fallback

        total = sum(c["w"] for c in usable) or 1.0

        # основной цвет — самый заметный, но с предпочтением более «цветным»
        dominant = max(usable, key=lambda c: c["w"] * (0.5 + c["s"]))

        # акцент — самый «живой»: насыщенный, яркий и при этом не редкий
        accent = max(usable, key=lambda c: math.sqrt(c["w"] / total) * c["s"] * (0.35 + c["v"]))

        chosen = [dominant]

        # хватает ли цвету отличия от уже выбранных
        def far_enough(c, min_d=38):
            return all(rgb_dist(c["rgb"], o["rgb"]) >= min_d for o in chosen)

        # второй — родственный по оттенку (как раньше), но заметно отличающийся от основного
        cands = [c for c in usable if c is not dominant and far_enough(c)]
        analog = [c for c in cands if hue_dist(c["h"], dominant["h"]) < 0.18]
        second = max(analog or cands, key=lambda c: c["w"], default=None) if (analog or cands) else None
        if second is None:
            others = [c for c in items if c is not dominant]
            second = max(others, key=lambda c: c["w"], default=dominant)
        chosen.append(second)

        # третий — максимально непохожий на два предыдущих, но не случайная мелочь
        rest = [c for c in usable if c not in chosen]
        if rest:
            third = max(rest, key=lambda c: math.sqrt(c["w"]) * min(rgb_dist(c["rgb"], o["rgb"]) for o in chosen))
        else:
            others = [c for c in items if c not in chosen]
            third = max(others, key=lambda c: c["w"], default=second)
        chosen.append(third)

        return {
            "palette": [rgb_to_hex(c["rgb"]) for c in chosen],
            "accent": rgb_to_hex(accent["rgb"]),
        }

    except Exception as e:
        print(f"Не удалось разобрать {path}: {e}", file=sys.stderr)
        return fallback


# ======================= ТЕМА =======================

# Собирает тему (bg / border / accent / subtext / secondary / text) из палитры обоев и акцента.
# Везде следим за контрастом относительно фона, чтобы текст и иконки не сливались
def build_theme(palette, accent_hex):
    dom = hex_to_rgb(palette[0])
    hd, sd, _ = to_hsv(dom)
    colorful = sd > 0.08

    # фон панели: очень тёмный оттенок обоев (или классический #181825)
    if TINT_BG and colorful:
        bg = from_hls(hd, 0.085, clamp(0.15 + sd * 0.35, 0.15, 0.40))
    else:
        bg = hex_to_rgb(DEFAULT_BG)

    # акцент: яркий и сочный, но не ядовитый; серые обои насильно не «красим»
    ha, sa, va = to_hsv(hex_to_rgb(accent_hex))
    if sa >= 0.10:
        sa = clamp(max(sa, 0.5), 0.5, 0.9)
    va = max(va, 0.80)
    accent = push_lightness(from_hsv(ha, sa, va), bg, 7.0, lighten=True)

    # текст и приглушённый текст — светлые, с лёгким оттенком обоев
    ht = hd if colorful else 0.66
    text = push_lightness(from_hls(ht, 0.92, 0.20 if colorful else 0.12), bg, 10.0)
    subtext = push_lightness(from_hls(ht, 0.72, 0.15 if colorful else 0.10), bg, 5.0)

    # secondary: и подложка под иконкой акцентного цвета, и цвет второстепенного текста.
    # Поэтому он должен отличаться от фона (>= 2.3) и оставаться темнее акцента (>= 3.0).
    # Оттенок берём у АКЦЕНТА (как у бара и рамок), а не у «самого непохожего» третьего цвета палитры —
    # иначе на зелёных обоях с небом secondary выходил синим и лаунчер выбивался из общей темы
    sec = from_hls(ha, 0.30, clamp(sa * 0.6, 0.25, 0.55) if sa >= 0.10 else 0.18)
    sec = push_lightness(sec, bg, 2.3, lighten=True)
    if contrast(accent, sec) < 3.0:
        sec = push_lightness(sec, accent, 3.0, lighten=False)
        if contrast(sec, bg) < 1.6:       # совсем не осталось места — осветляем акцент
            accent = push_lightness(accent, sec, 3.0, lighten=True)

    # border: оттенок второго цвета палитры, средней светлоты
    h2, s2, _ = to_hsv(hex_to_rgb(palette[1]))
    border = from_hls(h2, 0.45, clamp(s2, 0.25, 0.60) if s2 > 0.08 else 0.15)
    border = push_lightness(border, bg, 2.5, lighten=True)

    return {
        "bg": rgb_to_hex(bg),
        "border": rgb_to_hex(border),
        "accent": rgb_to_hex(accent),
        "subtext": rgb_to_hex(subtext),
        "secondary": rgb_to_hex(sec),
        "text": rgb_to_hex(text),
    }


# ======================= ФАЙЛЫ =======================

# Пишет файл атомарно: сначала во временный, потом подменяет целиком.
# Так читатели (FileView в QML) никогда не увидят половину файла
def atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# Читает кеш палитр. Если файла нет, он битый или версия алгоритма другая — начинаем с чистого
def load_palettes():
    try:
        with open(PALETTES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and data.get("__v") == ALGO_VERSION:
            return data
    except Exception:
        pass
    return {"__v": ALGO_VERSION}


# Подставляет цвета рамок окон в конфиг Hyprland и перезагружает его.
# Если цвета не поменялись — конфиг не трогаем и reload не дёргаем
def update_hyprland(accent, inactive):
    if not os.path.exists(HYPRLAND_CONF):
        return
    try:
        with open(HYPRLAND_CONF, "r", encoding="utf-8") as f:
            content = f.read()

        a = accent.lstrip("#")
        i = inactive.lstrip("#")
        new_active = 'active_border = { colors = {"rgba(%sff)", "rgba(%sff)"}, angle = 135 }' % (a, a)
        new_inactive = 'inactive_border = "rgba(%sff)"' % i

        updated = re.sub(r'active_border\s*=\s*\{\s*colors\s*=\s*\{[^}]*\}[^}]*\}', lambda m: new_active, content)
        updated = re.sub(r'inactive_border\s*=\s*"[^"]*"', lambda m: new_inactive, updated)

        if updated == content:
            return

        atomic_write(HYPRLAND_CONF, updated)
        try:
            subprocess.run(["hyprctl", "reload"], timeout=10, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
    except Exception as e:
        print(f"Ошибка при обновлении конфига Hyprland: {e}", file=sys.stderr)


# Обходит папку с обоями (включая подпапки) и отдаёт пути ко всем картинкам
def iter_wallpapers():
    if not os.path.isdir(WALLPAPER_DIR):
        return
    for root_dir, _dirs, files in os.walk(WALLPAPER_DIR):
        for name in files:
            if name.lower().endswith(IMAGE_EXT):
                yield os.path.join(root_dir, name)


# ======================= MAIN =======================

# Точка входа: если передали обои — применяем тему из них; в любом случае досчитываем
# палитры новых обоев и выкидываем из кеша удалённые
def main():
    os.makedirs(CACHE_DIR, exist_ok=True)

    target = None
    if len(sys.argv) > 1:
        arg = os.path.abspath(sys.argv[1].strip())
        if os.path.isfile(arg):
            target = arg

    # wall.qml запускает скрипт и при старте, и при выборе обоев — не даём им писать файлы одновременно
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        palettes = load_palettes()

        if target:
            res = extract(target)
            palettes[target] = res["palette"]

            theme = build_theme(res["palette"], res["accent"])
            atomic_write(COLORS_FILE, json.dumps(theme, separators=(",", ":")) + "\n")    # одна строка + перевод строки
            update_hyprland(theme["accent"], theme["secondary"])

        # досчитываем палитры новых обоев и убираем удалённые
        existing = set()
        for path in iter_wallpapers():
            existing.add(path)
            if path not in palettes:
                palettes[path] = extract(path)["palette"]
        for key in [k for k in palettes if k != "__v" and k not in existing and k != target]:
            del palettes[key]

        atomic_write(PALETTES_FILE, json.dumps(palettes, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
