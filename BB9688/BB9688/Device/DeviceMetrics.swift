//
//  DeviceMetrics.swift
//  BB9688
//
//  机身几何：全部是相对图片尺寸的百分比，来自 Prototype/build_shell.py 实测输出
//  （device-shell.json / glow-map.json）。
//  换一张产品图只要重跑那个脚本，把这里的数字替换掉即可。
//

import CoreGraphics
import Foundation

enum DeviceMetrics {
    /// 机身图片宽高比（device-shell.png 为 910 × 1567）
    static let aspect: CGFloat = 910.0 / 1567.0

    /// 屏幕玻璃区（240×320 画布画在这里）
    static let screen = CGRect(x: 0.1164835, y: 0.1295469,
                              width: 0.7626374, height: 0.5788130)

    /// 摇杆：圆心 + 半径（半径按宽度取百分比）
    static let stickCenter = CGPoint(x: 0.4950549, y: 0.8337588)
    static let stickRadius: CGFloat = 0.1502747          // 136.5 / 910
    /// 方向点簇离圆心的半径（占宽度）
    static let dotRadius: CGFloat = 0.0846154            // 77 / 910

    /// 左右两个椭圆键
    static let backButton = CGRect(x: 0.0637363, y: 0.7957881,
                                   width: 0.2340659, height: 0.0753031)
    static let menuButton = CGRect(x: 0.6934066, y: 0.7970644,
                                   width: 0.2307692, height: 0.0740268)

    /// 左侧电源键（机身侧边凸起那一块）
    static let powerButton = CGRect(x: 0, y: 0.234,
                                    width: 0.032, height: 0.134)

    /// 按下时叠加的辉光层，坐标为 (x, y, w, h)
    static let glows: [String: CGRect] = [
        "back":   CGRect(x: 0.04725, y: 0.78494, width: 0.27143, height: 0.09700),
        "menu":   CGRect(x: 0.67143, y: 0.78558, width: 0.27582, height: 0.09700),
        "up":     CGRect(x: 0.44615, y: 0.75877, width: 0.09670, height: 0.04595),
        "down":   CGRect(x: 0.44615, y: 0.86152, width: 0.09451, height: 0.04659),
        "left":   CGRect(x: 0.36154, y: 0.80791, width: 0.08352, height: 0.05105),
        "right":  CGRect(x: 0.54176, y: 0.80791, width: 0.08571, height: 0.05105),
        "center": CGRect(x: 0.42857, y: 0.79515, width: 0.13187, height: 0.07658)
    ]

    /// 屏幕逻辑尺寸
    static let screenWidth = 240
    static let screenHeight = 320

    /// 画布宽高比。注意它和 `screen` 矩形的宽高比（≈0.765）并不相等 ——
    /// 玻璃区是从机身照片里量出来的，比 240:320 宽约 2%。
    /// 画布必须按这个比例等比放置，直接铺满玻璃区就是横向拉伸（圆会变椭圆）。
    static let canvasAspect: CGFloat = CGFloat(screenWidth) / CGFloat(screenHeight)
}
