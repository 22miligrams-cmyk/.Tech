// BarBlur.qml
//
// Зачем это: размытое "стекло" под баром. Берёт готовую текстуру того, что
// сейчас на экране (обои + окна, её делает LiveBackdrop), вырезает кусок ровно
// под плашку бара, скругляет углы, размывает шейдером bar_blur.frag.qsb и
// подкрашивает tint-ом. Без этого прозрачный бар просто бы показывал резкий фон.
//
// Как юзать: BarBlur { source: backdrop.texture; rect: ({x:0,y:0,w:300,h:40}) }

import QtQuick
import "../panels"
import "../notifications"
import "../settings"
import "../common"

ShaderEffect {
    id: root

    // текстура, которую размываем (из LiveBackdrop)
    property Item source

    // размер исходника, нужен пока у source нет своего sourceRect
    property size srcSize: Qt.size(1, 1)

    // где левый-верхний угол нашего экрана относительно текстуры
    property real originX: 0;  property real originY: 0

    // прямоугольник, который вырезаем и рисуем (x, y, w, h)
    property var rect: ({ x: 0, y: 0, w: 0, h: 0 })
    property real cornerRadius: 6

    // радиусы по углам, чтобы можно было скруглять не все
    property vector4d corners: Qt.vector4d(cornerRadius, cornerRadius, cornerRadius, cornerRadius)
    property real blurRadius: 14
    property color tint: "transparent"

    // сила эффекта 0..1, при ~0 шейдер вообще выключается
    property real strength: 1

    // сам эффект ставим ровно на место плашки
    x: rect.x
    y: rect.y
    width: rect.w;  height: rect.h
    visible: source !== null && width >= 1 && height >= 1 && strength > 0.01
    opacity: strength

    // это всё уходит в шейдер: размер, радиусы (не больше половины стороны), радиус блюра
    property size itemSize: Qt.size(width, height)
    property real maxR: Math.min(width, height) / 2
    property vector4d radii: Qt.vector4d(Math.min(corners.x, maxR), Math.min(corners.y, maxR),
                                         Math.min(corners.z, maxR), Math.min(corners.w, maxR))
    property real blurPx: blurRadius

    // какой кусок текстуры реально используем: sourceRect если есть, иначе весь srcSize
    readonly property rect srcRect: {
        const sr = source ? source.sourceRect : undefined
        if (sr !== undefined && sr.width > 0 && sr.height > 0)
            return Qt.rect(sr.x, sr.y, sr.width, sr.height)
        return Qt.rect(0, 0, Math.max(1, srcSize.width), Math.max(1, srcSize.height))
    }

    // размер одного пикселя в координатах текстуры + область и цвет подкраски для шейдера
    property size texel: Qt.size(1 / Math.max(1, srcRect.width), 1 / Math.max(1, srcRect.height))
    property vector4d region: Qt.vector4d(
        (originX + x - srcRect.x) / Math.max(1, srcRect.width),
        (originY + y - srcRect.y) / Math.max(1, srcRect.height),
        width / Math.max(1, srcRect.width),
        height / Math.max(1, srcRect.height))
    property vector4d tintColor: Qt.vector4d(tint.r, tint.g, tint.b, tint.a)

    // скомпилированный шейдер лежит в assets
    fragmentShader: Qt.resolvedUrl("../assets/bar_blur.frag.qsb")

    // пишем в лог если шейдер не собрался (иначе просто молча не видно блюра)
    onStatusChanged: {
        if (status === ShaderEffect.Error)
            console.log("[BarBlur] shader error:", log)
        else if (status === ShaderEffect.Compiled)
            console.log("[BarBlur] shader ok,", width + "x" + height)
    }
}
