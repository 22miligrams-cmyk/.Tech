#!/usr/bin/env python3
# визуализатор для MprisPanel, без cava
# слушаем что играет в системе (monitor вывода) через parec или pw-record,
# режем на 20 полос и выводим строчку типа "0.123 0.456 ..." (от 0 до 1)
# раз 30 в секунду. numpy не обязателен, но с ним быстрее
import sys, math, signal, subprocess, shutil
from array import array

RATE = 16000
N = 512            # размер окна для fft
BANDS = 20
FMIN, FMAX = 50.0, 7000.0

try:
    import numpy as np
except Exception:
    np = None   # ну и ладно, посчитаем без него


hann = [0.5 - 0.5*math.cos(2*math.pi*i/(N-1)) for i in range(N)]
edges = [FMIN * (FMAX/FMIN) ** (i/BANDS) for i in range(BANDS+1)]
centers = [math.sqrt(edges[i]*edges[i+1]) for i in range(BANDS)]


if np is not None:
    win = np.array(hann)
    freqs = np.fft.rfftfreq(N, 1.0/RATE)
    idx = []
    for i in range(BANDS):
        sel = np.where((freqs >= edges[i]) & (freqs < edges[i+1]))[0]
        if len(sel) == 0:
            # в низах полоса может быть уже чем шаг fft, берём ближайшую
            sel = np.array([int(np.argmin(np.abs(freqs - centers[i])))])
        idx.append(sel)

    def spectrum(buf):
        x = np.frombuffer(buf, dtype=np.int16).astype(np.float64) * win
        mag = np.abs(np.fft.rfft(x)) / (N/4.0) / 32768.0
        return [float(mag[s].max()) for s in idx]

else:
    # без numpy считаем алгоритмом гёрцеля, медленнее но работает
    coeffs = [2*math.cos(2*math.pi*c/RATE) for c in centers]

    def spectrum(buf):
        a = array('h')
        a.frombytes(buf)
        xs = [s*w for s, w in zip(a, hann)]
        out = []
        for co in coeffs:
            s1 = s2 = 0.0
            for x in xs:
                s0 = x + co*s1 - s2
                s2 = s1
                s1 = s0
            p = s1*s1 + s2*s2 - co*s1*s2
            out.append(math.sqrt(max(p, 0.0)) / (N/4.0) / 32768.0)
        return out


TILT = 1.5        # подъём в дб на каждую полосу, а то верха в музыке мало и он не двигается
FLOOR_DB = 72.0   # всё что тише - тишина (больше число = чувствительнее)
RANGE_DB = 48.0   # динамический диапазон одной полосы
bpeak = [0.45] * BANDS   # макс для каждой полосы, чтоб подстраивалось под громкость


def to_levels(mags):
    if max(mags) < 1e-5:
        return [0.0]*BANDS   # совсем тихо
    out = []
    for i, m in enumerate(mags):
        db = 20.0 * math.log10(m + 1e-9) + i*TILT
        v = min(1.0, max(0.0, (db + FLOOR_DB) / RANGE_DB))
        bpeak[i] = max(bpeak[i]*0.995, v, 0.45)
        out.append(min(1.0, (v / bpeak[i]) ** 1.4))
    return out


child = None

def bye(*_):
    # убиваем parec/pw-record чтоб не висели в фоне
    if child is not None:
        try:
            child.kill()
        except Exception:
            pass
    sys.exit(0)

signal.signal(signal.SIGTERM, bye)
signal.signal(signal.SIGINT, bye)


def commands():
    # сначала пробуем parec, если нет то pw-record
    if shutil.which("parec"):
        yield ["parec", "-d", "@DEFAULT_MONITOR@", "--format=s16le",
               "--rate=%d" % RATE, "--channels=1", "--latency-msec=20"]
    if shutil.which("pw-record"):
        yield ["pw-record", "-P", "stream.capture.sink=true", "--format=s16",
               "--rate=%d" % RATE, "--channels=1", "-"]


def run(cmd):
    global child
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    need = N*2   # int16 = 2 байта
    while True:
        buf = b""
        while len(buf) < need:
            chunk = child.stdout.read(need - len(buf))
            if not chunk:
                return   # поток закончился
            buf += chunk
        lv = to_levels(spectrum(buf))
        sys.stdout.write(" ".join("%.3f" % v for v in lv) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    for c in commands():
        try:
            run(c)
        except OSError:
            continue
    sys.exit(1)   # ни одна команда не сработала
