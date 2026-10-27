//
//  CoreTextRenderer.swift
//  BB9688
//
//  BBTextRenderer 的 iOS 实现：用 CoreText 把文字画进 240×320 的软件画布。
//
//  对齐原实现（screen.cc → ShowText）：
//    · 先按 Transparent==false 铺一层背景色矩形，再把字形贴上去；
//    · 步进 = 该字形渲染出来的宽度（不是固定字宽）；
//    · 行高 = 字号 + 2，换行时 y += 行高 - 1；
//    · LOCATE 的列宽 = 一个空格串的宽度（TTF_SizeText(" ")）。
//
//  字形蒙版按 (字体, 字符) 缓存，颜色在贴图时再上，避免重复栅格化。
//

import CoreGraphics
import CoreText
import Foundation
import UIKit

public final class CoreTextRenderer: BBTextRenderer {

    // MARK: - 字形蒙版

    /// 字形蒙版。width 同时是「贴图宽度」和「步进宽度」——
    /// 原实现里 Text->w 一个值身兼两职（FillRect 宽度 / Blit 宽度 / OutputPosition 步进），
    /// 这里保持一致，否则字距会越走越偏。
    private struct GlyphMask {
        var width: Int
        var height: Int
        /// 这张蒙版上到底有没有画出东西（字体缺字时会是 false）
        var hasInk: Bool
        /// 逻辑步进（HD 下 = 位图宽度 / scale），VM 的字距按这个走
        var advance: Int
        var alpha: [UInt8]
    }

    private var fontID = 0
    private var ctFont: CTFont
    private var ascent: CGFloat = 0
    private var descent: CGFloat = 0
    private var spaceWidth: CGFloat = 0

    private var cache: [Int: GlyphMask] = [:]
    private var cacheKeys: [Int] = []

    /// 供栅格化用的字体：同族、字号 = 逻辑字号 × `BBHD.scale`。
    /// 和 `ctFont` 分开是必须的 —— `ctFont` 要维持逻辑字号（`metrics`、行高、
    /// 列宽都靠它算），画字形则必须用放大后的字号。
    private var ctFontPx: CTFont?
    private var pxScale = 0

    public init() {
        ctFont = CoreTextRenderer.makeFont(fontID: 0)
        refreshMetrics()
    }

    // MARK: - 字体

    /// 宋 / 楷 / 黑，按 iOS 上真实存在的字体名依次尝试。
    /// 拿到一定把它归一化成 PostScript 名：`UIFont(name:)` 能吃家族名，
    /// 但 `CTFontCreateWithName` 只认 PostScript 名，喂家族名会静默退回 Helvetica，
    /// 于是汉字全变成缺字。
    private static func fontName(family: Int) -> String? {
        let names: [[String]] = [
            ["STSongti-SC-Regular", "Songti SC", "STSongti-SC-Light", "STSong", "Songti TC"],
            ["STKaitiSC-Regular", "Kaiti SC", "STKaiti", "Kaiti TC"],
            ["PingFangSC-Regular", "PingFang SC", "Heiti SC",
             "STHeitiSC-Medium", "Heiti TC"]
        ]
        let list = names[max(0, min(2, family))]
        for name in list {
            if let font = UIFont(name: name, size: 12) {
                return font.fontName           // PostScript 名
            }
        }
        return nil
    }

    private static func makeFont(fontID: Int) -> CTFont {
        let size = CGFloat(BBFontTable.size(for: fontID))
        let family = BBFontTable.family(for: fontID)
        if let name = fontName(family: family) {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        // 兜底：系统字体（黑体观感最接近）
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        return CTFontCreateWithName(base.fontName as CFString, size, nil)
    }

    /// 让 CoreText 针对这段文字挑一个真的能画出字形的字体。
    /// 宋/楷体在部分 iOS 版本上并不完整覆盖 GB2312，直接画会静默丢字。
    private static func fontCovering(_ base: CTFont, _ text: String) -> CTFont {
        let ns = text as NSString
        guard ns.length > 0 else { return base }
        return CTFontCreateForString(base, text as CFString,
                                     CFRange(location: 0, length: ns.length))
    }

    private func refreshMetrics() {
        ascent = CTFontGetAscent(ctFont)
        descent = CTFontGetDescent(ctFont)

        // 原实现在 simsun / simkai / simhei 上取 TTF_SizeText(" ")，
        // 这三套字体的空格都恰好是 0.5 em，于是 FontWidth == 字号 / 2，
        // 而且它是**按字节**算的宽度（一个汉字 = 2 × FontWidth）。
        // iOS 上各字体空格宽度并不一致（PingFang 就偏窄），若直接照搬平台值，
        // LOCATE 的列宽、\t 的跳格都会整体跑偏，棋盘/表格类程序会挤成一团。
        // 所以这里固定按 0.5 em 取值，对齐原机器。
        spaceWidth = CGFloat(BBFontTable.size(for: fontID)) * 0.5
    }

    public func setFont(_ fontID: Int) {
        guard fontID != self.fontID else { return }
        self.fontID = fontID
        ctFont = CoreTextRenderer.makeFont(fontID: fontID)
        ctFontPx = nil
        pxScale = 0
        refreshMetrics()
    }

    /// 放大后的字体（只用于画字形）。倍率变了会自动重建。
    private func pixelFont() -> CTFont {
        let s = BBHD.scale
        if pxScale == s, let f = ctFontPx { return f }
        let size = CGFloat(BBFontTable.size(for: fontID)) * CGFloat(s)
        let f = CTFontCreateCopyWithAttributes(ctFont, size, nil, nil)
        ctFontPx = f
        pxScale = s
        return f
    }

    public var metrics: BBTextMetrics {
        // 行高取 TTF_FontHeight 的等价：ascent + descent 向上取整，且不小于 字号+2
        let natural = Int(ceil(ascent + descent))
        let lineHeight = max(BBFontTable.lineHeight(for: fontID), natural)
        return BBTextMetrics(cellWidth: Int(spaceWidth.rounded()), lineHeight: lineHeight)
    }

    // MARK: - 栅格化

    /// 把字符画进一张灰度位图，得到 alpha 蒙版
    ///
    /// 关键点（踩过的坑）：
    ///   · CTLineDraw **不读**上下文的填充色。缺 `kCTForegroundColorAttributeName`
    ///     且 `kCTForegroundColorFromContextAttributeName` 为默认 false 时，
    ///     CoreText 一律用黑色画 —— 黑底上画黑字，蒙版全 0，屏幕上一个字都没有。
    ///     所以这里必须显式给白色前景色。
    ///   · 位图高度锁死在行高（= TTF_FontHeight 的等价），基线按 descent 从底部抬起，
    ///     这样每个字符占的格子和 NewLine 走的行网格完全对齐；
    ///     用墨迹框（glyph bounds）自适应反而会让相邻行互相啃。
    private func mask(for text: String) -> GlyphMask {
        let key = fontID &* 131_071 &+ text.unicodeScalars.reduce(0) { $0 &* 131 &+ Int($1.value) }
        if let hit = cache[key] { return hit }

        // ★ 栅格化用的字体必须是**放大后**的字号。
        //   以前这里直接拿 `ctFont`（逻辑字号，12pt）去画，却把位图按 12·s 开，
        //   于是 s=3 时字形只占格子左边三分之一、右边留白 —— 屏幕上看就是
        //   「字变小了、字距还散开」。位图尺寸和字号必须同步放大，否则越放大越小。
        let s = CGFloat(BBHD.scale)
        let drawFont = CoreTextRenderer.fontCovering(pixelFont(), text)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): drawFont,
            // ← 白色前景：灰度上下文里就是 alpha=255
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: 1)
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)

        // 这一行是**像素**宽度（字体已经是 12·s 号了）
        let advancePx = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let pixelWidth = max(1, Int(advancePx.rounded(.up)))
        let boxHeight = max(1, Int((CGFloat(metrics.lineHeight) * s).rounded(.up)))
        // descent 也是像素值（取自放大后的字体），不要再乘 s
        let descentPx = max(0, Int(CTFontGetDescent(drawFont).rounded(.up)))
        // CGBitmapContext 的原点在左下（内存首行是图像顶行），
        // 所以基线要从**底部**抬起 descent 这么高，上面才刚好留出 ascent 的空间。
        let baselineY = max(0, descentPx)

        var alpha = [UInt8](repeating: 0, count: pixelWidth * boxHeight)
        alpha.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: pixelWidth,
                                      height: boxHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }

            // 底色涂黑 = alpha 0；字形用白色画进去 = alpha 255
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: boxHeight))
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.textPosition = CGPoint(x: 0, y: baselineY)
            CTLineDraw(line, ctx)
        }

        let result = GlyphMask(width: pixelWidth,
                               height: boxHeight,
                               hasInk: alpha.contains { $0 != 0 },
                               // 步进换算回**逻辑**像素：VM 的列宽/字距全按逻辑算，
                               // 只有画布是 s 倍。除回去和 1× 时的取整结果一致
                               // （12pt 汉字 36/3 = 12；5.4pt 数字 16.2/3 = 5.4 → 6）。
                               advance: max(1, Int((advancePx / s).rounded(.up))),
                               alpha: alpha)
        cache[key] = result
        cacheKeys.append(key)
        if cacheKeys.count > 3000 {
            for k in cacheKeys.prefix(1500) { cache.removeValue(forKey: k) }
            cacheKeys.removeFirst(1500)
        }
        return result
    }

    // MARK: - BBTextRenderer

    @discardableResult
    public func drawChar(_ bytes: [UInt8],
                         color: UInt32,
                         background: UInt32?,
                         on surface: BBSurface,
                         x: Int,
                         y: Int) -> Int {
        // 半角兜底步进：万一某个字节解不出字形，也不能让后面的字全部叠在同一个位置
        let halfCell = max(1, BBFontTable.size(for: fontID) / 2)

        let text = GBKCodec.decode(bytes)
        guard let ch = text.unicodeScalars.first else { return halfCell }

        // 换行 / 制表由 BBScreen 处理，这里只画可见字符
        if ch == "\n" || ch == "\t" { return 0 }

        let m = mask(for: text)
        let w = m.width
        let h = m.height
        let dx = x * BBHD.scale
        let dy = y * BBHD.scale

        if let bg = background {
            surface.fillRect(x: dx, y: dy, w: w, h: h, color: bg)
        }

        let r = (color >> 16) & 0xFF
        let g = (color >> 8) & 0xFF
        let b = color & 0xFF
        let rgb = (r << 16) | (g << 8) | b

        m.alpha.withUnsafeBufferPointer { buf in
            for row in 0..<h {
                let srcRow = row * w
                let dstY = dy + row
                for col in 0..<w {
                    let a = buf[srcRow + col]
                    if a == 0 { continue }
                    surface.blendPixel(dx + col, dstY, color: rgb, alpha: a)
                }
            }
        }

        // 步进：正常情况下就是原实现里的 Text->w（逻辑值）。
        // 只有当这个字根本没画出来（字体缺字 / 解码失败）时才补一个格子，
        // 否则一个空字形会让整行后面的字全部左移叠在一起。
        if !m.hasInk {
            return max(m.advance, bytes.count > 1 ? halfCell * 2 : halfCell)
        }
        return max(m.advance, 1)
    }
}
