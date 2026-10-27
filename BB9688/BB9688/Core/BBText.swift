//
//  BBText.swift
//  BB9688
//
//  文字渲染抽象。原 VM 用 SDL_ttf + 文泉/宋体/楷体/黑体点阵化；iOS 侧用 CoreText，
//  无头测试侧用占位渲染器，两者都实现这个协议。
//

import Foundation

public struct BBTextMetrics {
    /// 一个汉字的步进（也用于 LOCATE 的列宽）
    public var cellWidth: Int
    /// 行高
    public var lineHeight: Int

    public init(cellWidth: Int, lineHeight: Int) {
        self.cellWidth = cellWidth
        self.lineHeight = lineHeight
    }
}

public protocol BBTextRenderer: AnyObject {
    /// fontID = 字号索引 * 3 + 字体类型，字号 {12,16,24}，类型 {宋,楷,黑}
    func setFont(_ fontID: Int)
    var metrics: BBTextMetrics { get }

    /// 绘制单个字符（GBK 字节），返回步进宽度。
    /// background 不为 nil 时先铺底色（原 VM 的非透明模式）。
    @discardableResult
    func drawChar(_ bytes: [UInt8],
                  color: UInt32,
                  background: UInt32?,
                  on surface: BBSurface,
                  x: Int,
                  y: Int) -> Int
}

public enum BBFontTable {
    public static let sizes = [12, 16, 24]
    public static let families = ["宋体", "楷体", "黑体"]

    public static func size(for fontID: Int) -> Int {
        let idx = max(0, min(2, fontID / 3))
        return sizes[idx]
    }

    public static func family(for fontID: Int) -> Int {
        abs(fontID) % 3
    }

    public static func lineHeight(for fontID: Int) -> Int {
        size(for: fontID) + 2
    }
}

/// 文字探针：包在真正的渲染器外面，把每个画出来的字符顺手报一份。
///
/// 为什么需要它：黑市那种界面**没有任何图片能代表它** —— 商品名（催眠符、購地卡…）
/// 是字库渲染的真文字，资源号里什么都看不到。只能从「屏幕上出现了哪些字」来判断。
///
/// 只做转发，不改任何绘制行为；`onChar` 为空时开销就是一次可选链判空。
public final class BBTextProbe: BBTextRenderer {
    private let inner: BBTextRenderer
    /// 每画一个字符回调一次，参数是 GBK 字节（1~2 个）。
    public var onChar: (([UInt8]) -> Void)?

    public init(wrapping inner: BBTextRenderer) {
        self.inner = inner
    }

    public func setFont(_ fontID: Int) { inner.setFont(fontID) }

    public var metrics: BBTextMetrics { inner.metrics }

    @discardableResult
    public func drawChar(_ bytes: [UInt8],
                         color: UInt32,
                         background: UInt32?,
                         on surface: BBSurface,
                         x: Int,
                         y: Int) -> Int {
        onChar?(bytes)
        return inner.drawChar(bytes, color: color, background: background,
                              on: surface, x: x, y: y)
    }
}
