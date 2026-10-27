//
//  AppResources.swift
//  BB9688
//
//  Xcode 与 SwiftPM（xtool）的资源位置不同：
//    · Xcode：图片在 app bundle 根目录，Bundle.main 直接能找到；
//    · SwiftPM / xtool：资源被装进 BB9688_BB9688.bundle，要走 Bundle.module。
//
//  这个文件把差异吃掉，其它地方只认 AppResources / AppArtwork。
//

import Foundation
import UIKit

enum AppResources {

    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    /// Programs/（.bin + .LIB）所在目录
    ///
    /// 这里不能写死 `bundle/Programs`：Xcode 走「文件夹引用」，Programs 直接在 .app 根下；
    /// 而 SwiftPM / xtool 的 `.copy("Resources/Programs")` 会**保留相对路径**，
    /// 落到 `BB9688_BB9688.bundle/Resources/Programs`。
    /// 以前这里只有一种拼法，走 xtool 打出来的包就永远找不到 Programs → 一个程序都播种不进去，
    /// 列表里空空的，看着就是「打不开游戏」。现在按候选路径依次试，最后再浅层搜一遍。
    static var programsDirectory: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for base in [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent("Programs", isDirectory: true))
            candidates.append(base.appendingPathComponent("Resources/Programs", isDirectory: true))
        }
        for url in candidates where fm.fileExists(atPath: url.path) { return url }

        // 兜底：在 bundle 里找任意一层叫 Programs 的目录（不跟随符号链接，深度有限）
        if let base = bundle.resourceURL ?? Optional(bundle.bundleURL),
           let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                guard url.lastPathComponent == "Programs",
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                return url
            }
        }
        return candidates.first
    }

    /// 图片等散资源的 URL：先找 bundle 根，再找 `Resources/`（SwiftPM 的布局），
    /// 最后按文件名在 bundle 里搜一遍（不同打包方式放的位置不一样，宁可慢一次也别丢图）。
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let fm = FileManager.default
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        let target = "\(name).\(ext)"
        if let base = bundle.resourceURL {
            let alt = base.appendingPathComponent("Resources").appendingPathComponent(target)
            if fm.fileExists(atPath: alt.path) { return alt }
            if let e = fm.enumerator(at: base, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in e where url.lastPathComponent == target { return url }
            }
        }
        return nil
    }
}

/// 机壳与辉光贴图。数量少、尺寸固定，加载一次就缓存，
/// 避免每帧重建（辉光层在按下时会频繁切换透明度）。
enum AppArtwork {

    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        guard let url = AppResources.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[name] = image
        return image
    }

    static var shell: UIImage? { image("device-shell") }

    static func glow(_ key: String) -> UIImage? { image("glow-\(key)") }
}
