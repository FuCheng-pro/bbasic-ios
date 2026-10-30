//
//  BBRenderer.swift
//  BB9688
//
//  画布池 / 图片资源池 / 画笔，对应原 renderer.cc + outport 中 17~26、40~43、64~69、80 端口。
//

import Foundation

public final class BBGraphics {
    public weak var screen: BBScreen?

    private var pages: [BBSurface?] = Array(repeating: nil, count: BBConst.pageCount)
    private var resources: [BBSurface?] = Array(repeating: nil, count: BBConst.resourceCount)
    /// 索引 = page + 1（-1 表示屏幕），与原始实现的 _handle 一致
    private var penColors: [UInt32?] = Array(repeating: nil, count: BBConst.pageCount + 1)
    private var penStarts: [(x: Int, y: Int)] = Array(repeating: (0, 0), count: BBConst.pageCount + 1)

    private let library: BBResourceLibrary

    /// 诊断用：非 nil 时每笔 SHOWPIC 都回调一行文本（资源名、句柄、坐标）
    public var trace: ((String) -> Void)?
    /// 句柄 → "LIB序号|资源名"，供 trace 反查
    private var resourceNames: [Int: String] = [:]
    /// 句柄 → LIB 序号（纯数值，给场景识别用）
    private var resourceIndex: [Int: Int] = [:]

    /// 场景识别信号：每笔 SHOWPIC 报一次 `(LIB序号, 像素面积)`。
    ///
    /// 和 `trace` 分开的理由：`trace` 每次都拼一个 String（几十字节分配 + 格式化），
    /// 只能开着手动诊断用；这条是常开的，只传两个 Int，没有分配。
    /// 地图界面每帧会重绘几百笔，这个开销必须可控。
    public var onPictureDrawn: ((Int, Int) -> Void)?

    /// 画笔操作信号，参数是类型：1=填充 2=直线 3=矩形 4=圆。
    ///
    /// 为什么需要它：**游乐场那个「小碗接金币」的小游戏完全没有贴图**，
    /// 碗和金币都是用画笔现画的（圆 + 填充）。只看 `onPictureDrawn` 的话，
    /// 这类界面和「画面静止」长得一模一样，认不出来。
    ///
    /// 注意 `fillSurface` 每帧清屏都会调一次，别把它当强信号用；
    /// 真正有辨识度的是**圆**（地图和菜单几乎不画圆）。
    public var onPaintOp: ((Int) -> Void)?

    /// 金手指钩子：**每一笔贴图都会进来**，返回 false = 这一笔不画。
    ///
    /// 两个用处，都跟赌圣卡有关：
    ///  · 拦：赌场进门先把三粒骰面贴上去，紧接着又贴一张 86×46 的骰盅盖住它们，
    ///    把盖盅那一笔拦掉，玩家下注时看到的一直是游戏自己画的骰子。
    ///  · 记：顺手把「这一笔记的是哪一帧」告诉上层（`srcX`），于是面板上的点数和
    ///    屏幕上真正画出来的像素出自**同一个数** —— 不用再去猜内存里哪三个格是骰子
    ///    （实测那三格会被后续绘制复用，事后读出来是 2/2/1，而屏幕上是 2/5/5）。
    ///
    /// ⚠️ 地图一帧几百笔，实现里第一件事必须是纯整数比较，别在这里做任何查找。
    ///
    /// 参数：资源序号（RICH.LIB 的 #，认不出时 -1）、目标 x/y、宽、高、源图 x。
    public var onPicture: ((_ index: Int, _ dx: Int, _ dy: Int,
                           _ w: Int, _ h: Int, _ srcX: Int) -> Bool)?

    /// 洋红透明键（原实现用 0xFF00FF）
    public static let colorKey: UInt32 = 0xFF00FF

    public init(root: URL) {
        library = BBResourceLibrary(root: root)
        penColors[0] = 0xFFFFFF
    }

    public func surface(_ handle: Int) -> BBSurface? {
        if handle == -1 { return screen?.surface }
        guard handle >= 0, handle < BBConst.pageCount else { return nil }
        return pages[handle]
    }

    // MARK: - 画布

    public func allocSurface() -> Int {
        guard let screen else { return -1 }
        guard let idx = pages.firstIndex(where: { $0 == nil }) else { return -1 }
        pages[idx] = BBSurface(width: screen.width, height: screen.height, color: 0)
        return idx
    }

    public func freeSurface(_ index: Int) {
        guard index >= 0, index < BBConst.pageCount else { return }
        pages[index] = nil
        penColors[index + 1] = nil
    }

    public func cloneSurface(src srcHandle: Int, dst dstHandle: Int, x: Int, y: Int) {
        guard let src = surface(srcHandle), let dst = surface(dstHandle) else { return }
        var dx = BBHD.px(x), dy = BBHD.px(y)
        var cx = 0, cy = 0
        if dx < 0 { cx = -dx; dx = 0 }
        if dy < 0 { cy = -dy; dy = 0 }
        let w = min(src.width - cx, dst.width - dx)
        let h = min(src.height - cy, dst.height - dy)
        guard w > 0, h > 0 else { return }
        dst.blit(from: src, sx: cx, sy: cy, sw: w, sh: h, dx: dx, dy: dy, colorKey: BBGraphics.colorKey)
    }

    public func cloneSurfaceRegion(x: Int, y: Int, width: Int, height: Int,
                                   cx: Int, cy: Int,
                                   dst dstHandle: Int, src srcHandle: Int) {
        guard let src = surface(srcHandle), let dst = surface(dstHandle) else { return }
        let s = BBHD.scale
        dst.blit(from: src, sx: cx * s, sy: cy * s, sw: width * s, sh: height * s,
                 dx: x * s, dy: y * s, colorKey: BBGraphics.colorKey)
    }

    public func fillSurface(_ handle: Int, x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        onPaintOp?(1)
        guard let dst = surface(handle) else { return }
        let s = BBHD.scale
        // 原实现直接把颜色值交给 SDL_FillRect（按 RGB 解释）
        dst.fillRect(x: x * s, y: y * s, w: w * s, h: h * s, color: color)
    }

    public func writePixel(_ handle: Int, x: Int, y: Int, color: UInt32) {
        guard let dst = surface(handle) else { return }
        let s = BBHD.scale
        // 超采样下必须把 s×s 整块涂满，不能只点左上角那一个：
        // 「一个逻辑像素」在画布上就是 s×s，只点一个的话，画点类效果
        // （星图、光标、噪点）会变细 s 倍，跟 1× 不是一个观感。
        if s == 1 {
            dst.setPixel(x, y, bbSwapRB(color))
        } else {
            // 走 setPixel 而不是 fillRect：`fillRect` 那条路的颜色是按 RGB 直接解释的
            // （见 `fillSurface`），而「画点」传进来的是和 setPixel 一样的 BGR 序，
            // 换成 fillRect 会把红蓝对调。
            let c = bbSwapRB(color)
            for dy in 0 ..< s {
                for dx in 0 ..< s { dst.setPixel(x * s + dx, y * s + dy, c) }
            }
        }
    }

    public func readPixel(_ handle: Int, x: Int, y: Int) -> UInt32 {
        guard let src = surface(handle) else { return 0 }
        return bbSwapRB(src.pixel(BBHD.logical(x), BBHD.logical(y)))
    }

    // MARK: - 图片资源

    public func loadPicture(name: [UInt8], index: Int) -> Int {
        guard let image = library.image(named: name, index: index) else { return -1 }
        guard let idx = resources.firstIndex(where: { $0 == nil }) else { return -1 }
        resources[idx] = image
        resourceNames[idx] = "\(index)|\(GBKCodec.decode(name))"
        resourceIndex[idx] = index
        return idx
    }

    public func freePicture(_ handle: Int) {
        guard handle >= 0, handle < resources.count else { return }
        resources[handle] = nil
        resourceNames[handle] = nil
        resourceIndex[handle] = nil
    }

    public func picture(_ handle: Int) -> BBSurface? {
        guard handle >= 0, handle < resources.count else { return nil }
        return resources[handle]
    }

    public func pictureWidth(_ handle: Int) -> Int { picture(handle)?.logicalWidth ?? 0 }
    public func pictureHeight(_ handle: Int) -> Int { picture(handle)?.logicalHeight ?? 0 }

    /// SHOWPIC：把图片的一块贴到画布。
    /// HD 模式下源矩形和目标坐标都按 BBHD.scale 放大，1:1 贴到 4× 画布上。
    public func drawPicture(page: Int, pic: Int, dx: Int, dy: Int,
                            w: Int, h: Int, x: Int, y: Int, mode: Int) {
        let index = resourceIndex[pic] ?? -1
        guard let dst = surface(page), let src = picture(pic) else { return }
        // 场景识别信号照常发：它看的是「游戏想画什么」，和我们真画没画无关。
        if let onPictureDrawn, index >= 0 {
            onPictureDrawn(index, w * h)
        }
        if let hook = onPicture, !hook(index, dx, dy, w, h, x) { return }
        if let trace {
            trace("SHOWPIC page=\(page) pic=\(pic) [\(resourceNames[pic] ?? "?")] "
                  + "dst=(\(dx),\(dy)) src=(\(x),\(y)) \(w)x\(h) mode=\(mode)")
        }
        let s = BBHD.scale
        dst.blit(from: src, sx: x * s, sy: y * s, sw: w * s, sh: h * s,
                 dx: dx * s, dy: dy * s, colorKey: BBGraphics.colorKey)
    }

    // MARK: - 画笔

    public func setPenColor(_ handle: Int, color: UInt32) {
        let idx = handle + 1
        guard idx >= 0, idx <= BBConst.pageCount else { return }
        // 原实现按 BGR 解释：低字节 = R
        penColors[idx] = bbRGB(r: color & 0xFF, g: (color >> 8) & 0xFF, b: (color >> 16) & 0xFF)
    }

    public func movePen(_ handle: Int, x: Int, y: Int) {
        let idx = handle + 1
        guard idx >= 0, idx <= BBConst.pageCount, penColors[idx] != nil else { return }
        penStarts[idx] = (x * BBHD.scale, y * BBHD.scale)
    }

    public func drawLine(_ handle: Int, x: Int, y: Int) {
        onPaintOp?(2)
        let idx = handle + 1
        guard idx >= 0, idx <= BBConst.pageCount,
              let color = penColors[idx], let dst = surface(handle) else { return }
        let start = penStarts[idx]
        dst.drawLine(fromX: start.x, fromY: start.y,
                     toX: (x - 1) * BBHD.scale, toY: y * BBHD.scale, color: color)
        penStarts[idx] = (0, 0)
    }

    public func drawRectangle(_ handle: Int, x1: Int, y1: Int, x2: Int, y2: Int) {
        onPaintOp?(3)
        let idx = handle + 1
        guard idx >= 0, idx <= BBConst.pageCount,
              let color = penColors[idx], let dst = surface(handle) else { return }
        let s = BBHD.scale
        dst.drawRect(x1: x1 * s, y1: y1 * s, x2: x2 * s, y2: y2 * s, color: color)
    }

    public func drawCircle(_ handle: Int, x: Int, y: Int, r: Int) {
        onPaintOp?(4)
        let idx = handle + 1
        guard idx >= 0, idx <= BBConst.pageCount,
              let color = penColors[idx], let dst = surface(handle) else { return }
        dst.drawCircle(cx: x * BBHD.scale, cy: y * BBHD.scale,
                       radius: r * BBHD.scale, color: color)
    }
}

// MARK: - .lib 资源库

public final class BBResourceLibrary {
    private let root: URL
    private var cache: [String: Data] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// LIB 结构：count:u32 | offsets[count]:u32 | (len:u32, w:u16, h:u16, pad:u32, payload)*
    /// 原实现多读了 4 字节导致图片整体偏移 2 像素，这里按正确布局解析。
    ///
    /// `pad` 在本项目里被复用成**载荷倍率**（原格式里恒为 0）：0/1 = 原尺寸，4 = 已放大 4×。
    /// 详见 `decode(data:index:)`。
    ///
    /// HD：程序要的是 `RICH.LIB`，目录里若有 `RICH-HD.LIB` 就优先试它；
    /// 包里没覆盖这张图（offset 为 0）就回落到 `RICH.LIB`，由引擎按 BBHD.scale
    /// 做整数最近邻放大。所以「高清」不需要随包附一份 4× 素材，
    /// 只有单独重绘过的图才需要进 HD 包。
    public func image(named nameBytes: [UInt8], index: Int) -> BBSurface? {
        guard index >= 1 else { return nil }
        var name = GBKCodec.decode(nameBytes)
        name = name.replacingOccurrences(of: "\\", with: "/")
        while name.hasPrefix("/") { name.removeFirst() }

        let names: [String]
        if BBHD.isEnabled, let dot = name.lastIndex(of: ".") {
            names = [String(name[..<dot]) + "-HD" + String(name[dot...]), name]
        } else {
            names = [name]
        }

        for n in names {
            // 大小写兜底：程序里写 RICH.LIB，目录里可能是 rich.lib
            let url = BBFileResolver.url(forRelativePath: n, root: root)
            let key = url.path
            let data: Data
            if let cached = cache[key] {
                data = cached
            } else {
                guard let d = try? Data(contentsOf: url) else { continue }
                cache[key] = d
                data = d
            }
            if let s = BBResourceLibrary.decode(data: data, index: index) { return s }
        }
        return nil
    }

    /// HD 覆盖包的魔数（RICH-HD.LIB 的第一个 u32）。
    /// 原版 RICH.LIB 这个位置是图片张数（180 = 0xB4），不会撞上，见 `decode`。
    static let kHDMagic: UInt32 = 0x3144_4852   // "RHD1"

    /// 解码一条 LIB 记录。两种文件格式：
    ///
    /// **原版（RICH.LIB）** `count:u32 | offsets[count]:u32 | 记录…`
    ///   记录 = `len:u32, w:u16, h:u16, pad:u32, rsv:u32, RGB565…`，payload 恒为原尺寸（1×）。
    ///
    ///   ★ 记录头是 **16 字节**，不是 12。证据（180 张全一致）：
    ///     · `offsets[i+1] - offsets[i] - w*h*2 == 16`，一张不例外；
    ///     · `len == 12 + w*h*2`（len 从自己后面那个字节开始数）；
    ///     · o+12 那 4 字节在 180 张里**全是 0x00000000**，不可能是图像数据。
    ///   以前按 12 字节算，等于每一行都晚读 4 字节 = 2 个像素：整张图**右移 2px、
    ///   本行末尾 2px 回绕到行首**，于是面板左边凭空多出一条金线、右边少一截 ——
    ///   就是「右边跑到左边」的那个症状。四角是否 0xF81F（透明键）可以直接验：
    ///   按 16 算，065 四个角全是 0xF81F；按 12 算，左上角是 0x0000（黑）。
    ///
    /// **HD 覆盖包（RICH-HD.LIB）** `magic | count:u32 | offsets[count]:u32 | 记录…`
    ///   记录 = `len:u32, w:u16, h:u16, scale:u16, rsv:u16, RGB565…`
    ///   offsets[i] == 0 表示「本包不覆盖第 i+1 张」→ 返回 nil，让 image(named:) 回落 RICH.LIB。
    ///   scale 是这份 payload 已经放大过的倍率（1 或 4）。
    ///
    /// 引擎拿到 scale < BBHD.scale 的图（比如原版 1× 数据）会自己做整数最近邻放大，
    /// 所以「高清」不需要随包附一份 4× 素材 —— 逐像素结果和预存 4× 完全一样。
    public static func decode(data: Data, index: Int) -> BBSurface? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, index >= 1 else { return nil }

        let isHD = read32(bytes, 0) == kHDMagic
        let headerBase = isHD ? 4 : 0
        let count = Int(read32(bytes, headerBase))
        let offsetTable = headerBase + 4
        guard count > 0, index <= count, offsetTable + 4 * count <= bytes.count else { return nil }
        let offset = Int(read32(bytes, offsetTable + 4 * (index - 1)))
        guard offset > 0, offset + 16 <= bytes.count else { return nil }

        let w = Int(read16(bytes, offset + 4))
        let h = Int(read16(bytes, offset + 6))
        let payloadScale = isHD ? max(1, Int(read16(bytes, offset + 8))) : 1
        guard w > 0, h > 0, w < 8192, h < 8192 else { return nil }
        // 原版 16 字节头（末尾 4 字节恒为 0）；我自己打的 HD 覆盖包是 12 字节头。
        let dataStart = offset + (isHD ? 12 : 16)

        // 需要引擎自己放大几倍？不是整数倍就放弃放大（宁可糊一点也不要错位）
        var ratio = 1
        if BBHD.isEnabled, payloadScale < BBHD.scale,
           BBHD.scale % payloadScale == 0 {
            ratio = BBHD.scale / payloadScale
        }
        let outW = w * ratio
        let outH = h * ratio

        // VM 看到的仍是原图逻辑尺寸，坐标逻辑一行不用改
        let logicalW = max(1, w / payloadScale)
        let logicalH = max(1, h / payloadScale)

        let expect = w * h * 2
        let available = min(expect, max(0, bytes.count - dataStart))
        guard available >= 2 else { return nil }

        let surface = BBSurface(width: outW, height: outH,
                                logicalWidth: logicalW, logicalHeight: logicalH)

        @inline(__always)
        func rgb565(_ v: UInt16) -> UInt32 {
            let r = UInt32((v >> 11) & 0x1F)
            let g = UInt32((v >> 5) & 0x3F)
            let b = UInt32(v & 0x1F)
            return ((r * 255 / 31) << 16) | ((g * 255 / 63) << 8) | (b * 255 / 31)
        }

        if ratio == 1 {
            // 原样搬运（1× 包在非 HD 下、4× 包在 HD 下都走这里）
            var i = 0
            var p = 0
            while i + 1 < available && p < w * h {
                surface.pixels[p] = rgb565(UInt16(bytes[dataStart + i])
                                           | (UInt16(bytes[dataStart + i + 1]) << 8))
                i += 2
                p += 1
            }
        } else {
            // 整数最近邻放大：一个源像素 → ratio×ratio 的纯色方块。
            // 不做任何插值，字形/笔重/像素点与原始位图逐像素一致，只是每格变成方块。
            for y in 0 ..< h {
                let rowStart = y * w * 2
                for dy in 0 ..< ratio {
                    let dstRow = surface.pixels + (y * ratio + dy) * outW
                    for x in 0 ..< w {
                        let i = rowStart + x * 2
                        guard i + 1 < available else { break }
                        let c = rgb565(UInt16(bytes[dataStart + i])
                                       | (UInt16(bytes[dataStart + i + 1]) << 8))
                        dstRow.advanced(by: x * ratio).update(repeating: c, count: ratio)
                    }
                }
            }
        }
        return surface
    }

    @inline(__always)
    static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    @inline(__always)
    static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }
}
