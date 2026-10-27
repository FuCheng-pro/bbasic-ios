//
//  BBScreen.swift
//  BB9688
//
//  虚拟屏幕：输出光标、当前字体/颜色、CLS、LOCATE、文字逐字输出与自动换行。
//  对应原 screen.cc 中与「BB 程序可见行为」相关的部分（窗口/SDL 那套已去掉）。
//

import Foundation

public final class BBScreen {
    public private(set) var surface: BBSurface
    public let renderer: BBTextRenderer

    public var textColor: UInt32 = 0xFFFFFF
    public var backgroundColor: UInt32 = 0x000000
    public var transparent = false
    public var outputX = 0
    public var outputY = 0
    public private(set) var fontID = 0

    /// 画面有变化时通知宿主（UI 侧据此刷新）
    public var frameHook: (() -> Void)?

    /// 保护 `surface` 的**替换**。
    ///
    /// 这个锁解决的是一个会崩在完全无关地方的问题：VM 在后台线程跑，
    /// `IN 16` 会整个换掉 `surface`（旧对象被 release），而主线程的帧泵要读它。
    /// Swift 里 `let s = screen.surface` 编译成「取指针 + retain」两步，
    /// 这两步和后台的「存新值 + release 旧值」交错时，同一个对象会被多 release 一次，
    /// 引用计数下溢 → 之后任何一次 release 都会撞到已释放的内存。
    /// 2026-10-26 12:19 的崩溃正是这样：栈顶是
    /// `ViewGraph.beginNextUpdate → doDecrementSlow → _swift_release_dealloc`，
    /// 释放的是一个根本不存在的对象（x0 = 0，故障地址 0xfffffffffffffff0）。
    ///
    /// 所以主线程**不许**拿 `surface` 引用，只允许走 `copyFrame(into:)`，
    /// 在锁内把像素拷走。VM 线程自己读写 `surface` 不受影响（它和 setSize 同线程）。
    private let frameLock = NSLock()

    public init(width: Int = BBConst.defaultWidth,
                height: Int = BBConst.defaultHeight,
                renderer: BBTextRenderer) {
        // HD：画布是 240·s × 320·s，但 outputX/outputY 仍是逻辑坐标
        surface = BBSurface(width: width * BBHD.scale, height: height * BBHD.scale, color: 0)
        self.renderer = renderer
        renderer.setFont(0)
    }

    public var width: Int { surface.width }
    public var height: Int { surface.height }
    /// 逻辑尺寸（HD 下 = 240×320，程序看到的世界大小）
    public var logicalWidth: Int { surface.logicalWidth }
    public var logicalHeight: Int { surface.logicalHeight }

    public var fontWidth: Int { renderer.metrics.cellWidth }
    public var fontHeight: Int { renderer.metrics.lineHeight }

    public func setSize(width newWidth: Int, height newHeight: Int) {
        var w = max(1, newWidth)
        var h = max(1, newHeight)
        // 上限保护：端口里来的是 32 位寄存器，直接乘 scale 再乘起来会溢出 Int
        // （超出的部分是未定义行为，Swift 会 trap，或者分配一块荒唐大的缓冲）。
        w = min(w, 4096)
        h = min(h, 4096)
        if w == logicalWidth && h == logicalHeight { return }
        frameLock.lock()
        surface = BBSurface(width: w * BBHD.scale, height: h * BBHD.scale, color: 0)
        frameLock.unlock()
        outputX = 0
        outputY = 0
        frameHook?()
    }

    /// 主线程抓帧：整个「取画布 + 拷像素」都在锁内完成，**绝不把 surface 引用交出去**。
    /// 尺寸变了会在里面把 `buffer` 重新分配。
    /// 返回 nil 表示画布还没准备好（尺寸非法）。
    public func copyFrame(into buffer: inout [UInt32]) -> (width: Int, height: Int)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        let s = surface
        let w = s.width
        let h = s.height
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
        if buffer.count != w * h {
            buffer = [UInt32](repeating: 0, count: w * h)
        }
        buffer.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            d.update(from: s.pixels, count: w * h)
        }
        return (w, h)
    }

    public func clear() {
        surface.fill(backgroundColor)
        outputX = 0
        outputY = 0
        frameHook?()
    }

    public func setFont(_ id: Int) {
        fontID = id
        renderer.setFont(id)
    }

    public func setTextColor(front: UInt32, back: UInt32) {
        // 原实现：front/back 按 BGR 解释
        textColor = bbRGB(r: front & 0xFF, g: (front >> 8) & 0xFF, b: (front >> 16) & 0xFF)
        backgroundColor = bbRGB(r: back & 0xFF, g: (back >> 8) & 0xFF, b: (back >> 16) & 0xFF)
    }

    public func setTextLocation(row: Int, column: Int) {
        setDispPosition(x: fontWidth * (column - 1), y: fontHeight * (row - 1))
    }

    public func setDispPosition(x: Int, y: Int) {
        outputX = max(0, x)
        outputY = max(0, y)
    }

    public func newLine() {
        outputY += fontHeight - 1
        outputX = 0
        checkPosition()
    }

    private func checkPosition() {
        if outputX >= logicalWidth {
            newLine()
        }
        if outputY >= logicalHeight {
            outputX = 0
            outputY = 0
            surface.fill(backgroundColor)
        }
    }

    /// 逐字输出 GBK 字符串
    public func display(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 10 {                       // \n
                newLine()
                i += 1
                continue
            }
            if b == 9 {                        // \t：跳 8 个字符格
                outputX += fontWidth * 8
                checkPosition()
                i += 1
                continue
            }
            let len = GBKCodec.unitLength(bytes, at: i)
            let unit = Array(bytes[i..<min(bytes.count, i + len)])
            let advance = renderer.drawChar(unit,
                                            color: textColor,
                                            background: transparent ? nil : backgroundColor,
                                            on: surface,
                                            x: outputX,
                                            y: outputY)
            outputX += max(advance, 0)
            checkPosition()
            i += len
        }
        frameHook?()
    }

    public func display(_ text: String) {
        display(GBKCodec.encode(text))
    }

    public func displayNumber(_ value: Int32) {
        display(String(value))
    }

    public func displayFloat(_ value: Float) {
        // 原 VM 用 sprintf("%f")，固定 6 位小数
        display(String(format: "%f", value))
    }
}
