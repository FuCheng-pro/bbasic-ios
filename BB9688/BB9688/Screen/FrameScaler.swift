//
//  FrameScaler.swift
//  BB9688
//
//  LCD 只有 240×320，贴到 iPhone 上要放大到 ~881×1175（3.675 倍），不是整数倍。
//
//  ★ 为什么这里**不用** vImageScale 的高质量重采样（原来那套是 Lanczos）：
//    Lanczos / bicubic 的核带**负瓣**，遇到 1px 描边必振铃。实测（1D 检验，240→881）：
//        NEAREST    超出源数据局部极值的采样      0 个
//        BICUBIC                              45029 个，最大过冲 87 级
//        LANCZOS                              70037 个，最大过冲 107 级
//    大富翁的字、HUD 金边、骰子边框全是 1px 描边，107/255 的过冲等于在笔画两侧
//    各贴一道"亮一档 / 暗一档"的虚影；又因为 3.675 是小数，亮边和暗边并不对称，
//    看上去就是"右边那一小节跑到左边去了""描边旁边多一根线"。
//    这和位图落在哪、SD 还是 HD 都无关 —— 只要过这条缩放就中招。
//
//  ★ 所以：放大走**最近邻**（核宽 1，非负，数学上不可能振铃），
//    缩小走**面积平均**（核是矩形，同样非负）。两者都不会产生源图里不存在的值。
//    原来跟在缩放后面那道 3×3 拉普拉斯锐化也一并删掉了 —— 它本身也是振铃算子，
//    之前是为了补 Lanczos 的软才加的；最近邻放大根本不存在"软"，不需要补。
//
//  ★ 为什么直接吃 `[UInt32]` 而不是 CGImage：
//    画布是 0x00RRGGBB，UInt32 小端存进内存就是 B,G,R,A 字节序，即 4 通道 8 位交织。
//    省掉「CGImage → CGContext 解一遍」，既快又不会掉进 CGBitmapInfo 字节序的坑里。
//

import CoreGraphics
import Foundation

enum FrameScaler {

    /// 复用的目标缓冲。每帧分配一个百万级 [UInt32] 等于每秒几十 MB 的堆分配，
    /// 4× 画布（960×1280 → 882×1176，约 4.1MB）下这部分开销相当可观。
    private static var scaleBuf: [UInt32] = []

    /// 把画布重采样到目标**像素**尺寸。
    ///
    /// 放大（outW > width）用最近邻：一个源像素 → 连续 3~4 个纯色像素，绝不振铃。
    /// 缩小（HD 4× 画布）用面积平均：每个目标像素 = 它覆盖的那块源像素的平均色，
    /// 正好把原素材的棋盘网点重新平均成连续渐变。
    static func scaledImage(from pixels: [UInt32],
                            width: Int,
                            height: Int,
                            toWidth outW: Int,
                            toHeight outH: Int) -> CGImage? {
        guard width > 0, height > 0, outW > 1, outH > 1,
              pixels.count >= width * height else { return nil }

        if scaleBuf.count != outW * outH {
            scaleBuf = [UInt32](repeating: 0, count: outW * outH)
        }

        scaleBuf.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            pixels.withUnsafeBufferPointer { src in
                guard let s = src.baseAddress else { return }
                if outW >= width {
                    upscaleNearest(s, width, height, d, outW, outH)
                } else {
                    downscaleArea(s, width, height, d, outW, outH)
                }
            }
        }

        return makeImage(scaleBuf, width: outW, height: outH)
    }

    // MARK: - 索引表（每帧尺寸不变，只算一次）

    /// 放大用的列映射：目标列 → 源列
    private static var colOutW = -1
    private static var colSrcW = -1
    private static var colTable: [Int] = []
    /// 缩小用的源区间：目标列 → [源列起, 源列止)
    private static var spanOutW = -1, spanSrcW = -1
    private static var spanOutH = -1, spanSrcH = -1
    private static var spanX0: [Int] = []
    private static var spanX1: [Int] = []
    private static var spanY0: [Int] = []
    private static var spanY1: [Int] = []

    private static func ensureColumns(_ outW: Int, _ width: Int) {
        guard colOutW != outW || colSrcW != width || colTable.count != outW else { return }
        colTable = (0 ..< outW).map { min(width - 1, $0 * width / outW) }
        colOutW = outW
        colSrcW = width
    }

    private static func ensureSpans(_ outW: Int, _ width: Int, _ outH: Int, _ height: Int) {
        guard spanOutW != outW || spanSrcW != width || spanOutH != outH || spanSrcH != height
                || spanX0.count != outW || spanY0.count != outH else { return }
        spanX0 = (0 ..< outW).map { $0 * width / outW }
        spanX1 = (0 ..< outW).map { max($0 * width / outW + 1, ($0 + 1) * width / outW) }
        spanY0 = (0 ..< outH).map { $0 * height / outH }
        spanY1 = (0 ..< outH).map { max($0 * height / outH + 1, ($0 + 1) * height / outH) }
        spanOutW = outW; spanSrcW = width
        spanOutH = outH; spanSrcH = height
    }

    // MARK: - 放大：最近邻

    private static func upscaleNearest(_ s: UnsafePointer<UInt32>,
                                       _ width: Int, _ height: Int,
                                       _ d: UnsafeMutablePointer<UInt32>,
                                       _ outW: Int, _ outH: Int) {
        ensureColumns(outW, width)
        // 行映射按需算（差一行的代价远小于全表）
        colTable.withUnsafeBufferPointer { cp in
            guard let c = cp.baseAddress else { return }
            for dy in 0 ..< outH {
                let sy = min(height - 1, dy * height / outH)
                let drow = d + dy * outW
                let srow = s + sy * width
                for dx in 0 ..< outW {
                    drow[dx] = srow[c[dx]]
                }
            }
        }
    }

    // MARK: - 缩小：面积平均

    /// 目标像素 (dx,dy) 覆盖的源区间是 [dx*w/outW, (dx+1)*w/outW)，
    /// 取这块的平均色。矩形核非负，不会像 Lanczos 那样把亮边顶到 255 之外。
    private static func downscaleArea(_ s: UnsafePointer<UInt32>,
                                      _ width: Int, _ height: Int,
                                      _ d: UnsafeMutablePointer<UInt32>,
                                      _ outW: Int, _ outH: Int) {
        ensureSpans(outW, width, outH, height)
        guard spanX0.count == outW, spanY0.count == outH else { return }
        spanX0.withUnsafeBufferPointer { x0p in
            spanX1.withUnsafeBufferPointer { x1p in
                spanY0.withUnsafeBufferPointer { y0p in
                    spanY1.withUnsafeBufferPointer { y1p in
                        guard let x0 = x0p.baseAddress, let x1 = x1p.baseAddress,
                              let y0 = y0p.baseAddress, let y1 = y1p.baseAddress else { return }
                        for dy in 0 ..< outH {
                            let drow = d + dy * outW
                            for dx in 0 ..< outW {
                                var r = 0, g = 0, b = 0, n = 0
                                for sy in y0[dy] ..< y1[dy] {
                                    let srow = s + sy * width
                                    for sx in x0[dx] ..< x1[dx] {
                                        let c = srow[sx]
                                        r += Int((c >> 16) & 0xFF)
                                        g += Int((c >> 8) & 0xFF)
                                        b += Int(c & 0xFF)
                                        n += 1
                                    }
                                }
                                drow[dx] = UInt32(r / n) << 16 | UInt32(g / n) << 8 | UInt32(b / n)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 输出

    /// 0x00RRGGBB 画布 → CGImage（与 FrameEncoder 同一套 bitmapInfo）
    ///
    /// **不走 `Data(buffer:)`**。这个函数每帧（24fps）都要跑，缓冲区是百万像素级
    /// （iPhone 14 Pro 上约 1000×1400 = 5.6MB），而 `Data(buffer:)` 每次都要在
    /// Foundation 里做一次泛型 Sequence 特化 + 新建 `__DataStorage`。
    /// 2026-10-26 的崩溃日志就停在 `Data._Representation.init(_:)` 里（pc = 0，
    /// 取指时二级页表翻译失败）。这里改成自己 malloc 一块、memcpy 进去，
    /// 由 CGDataProvider 的释放回调负责 free —— 路径最短，也没有中间对象。
    static func makeImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let count = width * height
        guard count > 0, pixels.count >= count else { return nil }
        let byteCount = count * MemoryLayout<UInt32>.stride
        // 上限保护：尺寸算飞了（0 或荒谬大）时宁可这一帧不出图，也不要 malloc 一大块
        guard byteCount > 0, byteCount <= 32 * 1024 * 1024 else { return nil }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        pixels.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            bytes.copyMemory(from: UnsafeRawPointer(s), byteCount: byteCount)
        }

        guard let provider = CGDataProvider(dataInfo: nil,
                                            data: bytes,
                                            size: byteCount,
                                            releaseData: { _, ptr, _ in
            UnsafeMutableRawPointer(mutating: ptr).deallocate()
        }) else {
            bytes.deallocate()
            return nil
        }

        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
