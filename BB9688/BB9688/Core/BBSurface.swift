//
//  BBSurface.swift
//  BB9688
//
//  32 位画布 + 图元。像素格式内部统一 0xRRGGBB。
//  图元的绘制顺序、裁剪、颜色键（洋红透明）行为按原 renderer.cc 还原。
//

import Foundation

public final class BBSurface {
    public private(set) var width: Int
    public private(set) var height: Int
    public let pixels: UnsafeMutablePointer<UInt32>

    /// HD 资源用：位图实际是 4× 大小，但 VM 看到的仍是原始尺寸。
    /// 普通画布（屏幕/页）两者相等。
    public let logicalWidth: Int
    public let logicalHeight: Int

    public init(width: Int, height: Int, color: UInt32 = 0x000000,
                logicalWidth: Int? = nil, logicalHeight: Int? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.logicalWidth = max(1, logicalWidth ?? self.width)
        self.logicalHeight = max(1, logicalHeight ?? self.height)
        let count = self.width * self.height
        pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        pixels.initialize(repeating: color & 0xFFFFFF, count: count)
    }

    deinit {
        pixels.deinitialize(count: width * height)
        pixels.deallocate()
    }

    public func fill(_ color: UInt32) {
        let c = color & 0xFFFFFF
        pixels.update(repeating: c, count: width * height)
    }

    @inline(__always) public func setPixel(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color & 0xFFFFFF
    }

    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    public func fillRect(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        guard w > 0, h > 0 else { return }
        let c = color & 0xFFFFFF
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            let base = row * width
            for col in x0..<x1 {
                pixels[base + col] = c
            }
        }
    }

    /// 把一个 surface 的矩形区域贴到本 surface 的 (dx, dy)。
    /// colorKey 不为 nil 时，与之相等的源像素被跳过（原实现的洋红透明）。
    ///
    /// 性能要点（HD 4× 下每帧要搬 100 万级像素，逐像素带两道边界判断会直接掉到个位数帧率）：
    ///   · 裁剪区间只在**行外**算一次，行内不再判断 col 是否越界；
    ///   · 源行起止也用区间算好，内层是一个纯净的 for 循环；
    ///   · 没有透明键时整行走 memcpy（update(from:count:)），这是最快的路径；
    ///   · 有透明键时只做一次 `& 0xFFFFFF` 比较，按键值提前分支出两个循环。
    public func blit(from src: BBSurface,
                     sx: Int, sy: Int, sw: Int, sh: Int,
                     dx: Int, dy: Int,
                     colorKey: UInt32? = nil,
                     ignoreAlpha: Bool = true) {
        guard sw > 0, sh > 0 else { return }
        let y0 = max(0, dy), y1 = min(height, dy + sh)
        // 水平方向：目标列必须同时落在 [0,width) 和源列 [0,src.width) 里
        let c0 = max(max(0, dx), dx - sx)
        let c1 = min(min(width, dx + sw), dx - sx + src.width)
        guard c0 < c1, y0 < y1 else { return }

        let n = c1 - c0
        let srcColBase = sx + (c0 - dx)
        let key = colorKey.map { $0 & 0xFFFFFF }

        for row in y0 ..< y1 {
            let srcY = sy + (row - dy)
            guard srcY >= 0, srcY < src.height else { continue }
            let dstRow = pixels + row * width + c0
            let srcRow = src.pixels + srcY * src.width + srcColBase
            if let k = key {
                for i in 0 ..< n {
                    let v = srcRow[i] & 0xFFFFFF
                    if v != k { dstRow[i] = v }
                }
            } else {
                dstRow.update(from: srcRow, count: n)
            }
        }
    }

    /// 带透明度的像素混合（文字渲染用）
    @inline(__always)
    public func blendPixel(_ x: Int, _ y: Int, color: UInt32, alpha: UInt8) {
        guard alpha > 0, x >= 0, y >= 0, x < width, y < height else { return }
        let idx = y * width + x
        if alpha == 255 {
            pixels[idx] = color & 0xFFFFFF
            return
        }
        let dst = pixels[idx]
        let a = UInt32(alpha)
        let ia = 255 - a
        let r = ((((color >> 16) & 0xFF) * a) + (((dst >> 16) & 0xFF) * ia)) / 255
        let g = ((((color >> 8) & 0xFF) * a) + (((dst >> 8) & 0xFF) * ia)) / 255
        let b = (((color & 0xFF) * a) + ((dst & 0xFF) * ia)) / 255
        pixels[idx] = (r << 16) | (g << 8) | b
    }

    // MARK: - 图元

    public func drawLine(fromX x0: Int, fromY y0: Int, toX x1: Int, toY y1: Int, color: UInt32) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            setPixel(x, y, color)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// SDL_RenderDrawRect 的等价：描边（右上角各减 1，保持与原图元一致）
    public func drawRect(x1: Int, y1: Int, x2: Int, y2: Int, color: UInt32) {
        let minX = min(x1, x2), maxX = max(x1, x2)
        let minY = min(y1, y2), maxY = max(y1, y2)
        guard maxX >= minX, maxY >= minY else { return }
        for x in minX...maxX { setPixel(x, minY, color); setPixel(x, maxY, color) }
        if maxY > minY {
            for y in minY...maxY { setPixel(minX, y, color); setPixel(maxX, y, color) }
        }
    }

    public func drawCircle(cx: Int, cy: Int, radius: Int, color: UInt32) {
        guard radius >= 0 else { return }
        var x = 0, y = radius
        var p = 3 - 2 * radius
        func plot(_ xc: Int, _ yc: Int, _ px: Int, _ py: Int) {
            setPixel(xc + px, yc + py, color)
            setPixel(xc - px, yc + py, color)
            setPixel(xc + px, yc - py, color)
            setPixel(xc - px, yc - py, color)
            setPixel(xc + py, yc + px, color)
            setPixel(xc - py, yc + px, color)
            setPixel(xc + py, yc - px, color)
            setPixel(xc - py, yc - px, color)
        }
        while x < y {
            plot(cx, cy, x, y)
            if p < 0 {
                p += 4 * x + 6
            } else {
                p += 4 * (x - y) + 10
                y -= 1
            }
            x += 1
        }
        if x == y { plot(cx, cy, x, y) }
    }

    public func snapshot() -> [UInt32] {
        Array(UnsafeBufferPointer(start: pixels, count: width * height))
    }
}
