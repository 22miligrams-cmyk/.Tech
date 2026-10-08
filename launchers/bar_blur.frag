#version 440

// bar_blur.frag
//
// Шейдер блюра для «стеклянных» плашек (бар, карточки лаунчера, уведомления, консоль).
// Берёт кусок снимка экрана под плашкой, размывает его, подмешивает цветной оттенок
// и обрезает по скруглённому прямоугольнику со сглаженным краем.
//
// Важно: QML грузит не этот файл, а скомпилированный bar_blur.frag.qsb рядом с ним.
// После любой правки пересобирай:
//     qsb --qt6 -o bar_blur.frag.qsb bar_blur.frag
// (порядок и типы полей в буфере ниже должны совпадать со свойствами ShaderEffect в QML)

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;      // размер плашки, px
    float blurPx;       // радиус размытия, px
    vec2 texel;         // 1 / размер источника (px экрана -> uv)
    vec4 radii;         // радиусы углов, px: левый верх, правый верх, правый низ, левый низ
    vec4 region;        // x, y, w, h плашки внутри источника (0..1)
    vec4 tintColor;     // лёгкий цветной оттенок поверх размытия (rgba)
};

layout(binding = 1) uniform sampler2D source;

const int TAPS = 40;                // сколько выборок на пиксель (больше = глаже, но тяжелее)
const float GOLDEN = 2.39996323;    // золотой угол, для равномерной спирали


void main() {
    // где в источнике лежит этот пиксель плашки
    vec2 uv = region.xy + qt_TexCoord0 * region.zw;

    // Размытие по диску (спираль Фогеля) + mip-смещение, которое растёт с радиусом,
    // чтобы не было зерна. Центральная выборка идёт с весом 1, остальные — чем дальше, тем слабее
    float bias = clamp(log2(max(blurPx, 1.0) / 4.0) + 0.5, 1.0, 4.0);
    vec4 sum = texture(source, uv, bias);
    float wsum = 1.0;

    for (int i = 1; i <= TAPS; i++) {
        float t = float(i) / float(TAPS);
        float r = sqrt(t) * blurPx;
        float a = float(i) * GOLDEN;
        vec2 o = vec2(cos(a), sin(a)) * r * texel;
        float w = 1.0 - 0.5 * t;
        sum += texture(source, uv + o, bias) * w;
        wsum += w;
    }

    vec4 c = sum / wsum;                        // premultiplied: где под плашкой пусто — остаётся прозрачно
    vec3 col = mix(c.rgb, tintColor.rgb * c.a, tintColor.a);

    // Скруглённый прямоугольник (signed distance) со сглаженным краем:
    // выбираем радиус нужного угла и считаем расстояние до границы
    vec2 p = (qt_TexCoord0 - 0.5) * itemSize;
    float r = p.x > 0.0 ? (p.y > 0.0 ? radii.z : radii.y) : (p.y > 0.0 ? radii.w : radii.x);
    vec2 q = abs(p) - (itemSize * 0.5 - vec2(r));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float m = clamp(0.5 - d, 0.0, 1.0);         // 1 внутри, 0 снаружи, плавный переход на границе в ~1px

    fragColor = vec4(col, c.a) * m * qt_Opacity;
}
