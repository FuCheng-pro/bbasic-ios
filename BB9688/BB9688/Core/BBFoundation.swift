//
//  BBFoundation.swift
//  BB9688
//
//  BB 虚拟机的基础设施：常量、错误、GBK 字节串工具、类 C 随机数。
//  说明：BB 程序内部的字符串一律以 GBK 字节保存（与原 VM 的 char* 语义一致），
//  只在真正绘制/展示时才解码成 String，避免长度、切片语义走样。
//

import Foundation

public enum BBVMError: Error, CustomStringConvertible {
    case load(String)
    case fault(String)

    public var description: String {
        switch self {
        case .load(let m): return "载入失败：\(m)"
        case .fault(let m): return "虚拟机异常：\(m)"
        }
    }
}

public enum BBConst {
    /// 与原 VM 一致：2MB 虚拟内存
    public static let memorySize = 2 * 1024 * 1024
    /// 栈大小 1000 字节
    public static let stackSize = 1000
    /// 9688 的默认屏幕（竖屏 240x320）
    public static let defaultWidth = 240
    public static let defaultHeight = 320
    /// CREATEPAGE 的画布池数量
    public static let pageCount = 9
    /// 图片资源句柄上限（原实现用 map，理论上无限，这里给足余量）
    public static let resourceCount = 256
    /// 目标帧率，与原 VM 的 FPSNEED 一致
    public static let fps = 24

    /// 虚拟机目标执行速率（条/秒）——「原机速度」的基准，1.0× 就是它。
    ///
    /// 为什么必须节流：
    ///   BB BASIC 程序里大量动画是**纯计算循环**（逐格走地图、滚字、翻页），
    ///   原机上受 CPU 限制，手机上不受限 —— 不节流就是「什么都快进」，
    ///   骰子不用等、对话一秒刷完。2026-10-26 Release 构建后实测峰值能到
    ///   3~4M 条/秒，程序里再有 delay 也压不住中间的动画段。
    ///
    /// 50 万这个初值是按「老设备 16 位解释器」的量级给的：一条字节码要经过
    /// 取指、译码、分派、若干次内存访问，几十个时钟周期起步，主频 8~12MHz
    /// 折算下来就是几十万条/秒。
    ///
    /// **2026-10-26 已校准**：用户逐档试过后反馈「旧刻度 3×~4× 最像原机」。
    /// 旧刻度是 50 万一档，即 **150~200 万条/秒**。再看另一个旁证：旧代码
    /// （无虚拟时间轴，只有 16384 步/2ms 的防跑飞上限）实测爆发段 270~383
    /// 万条/秒，用户说它「比 4× 还快一倍」—— 4× 是 200 万，快一倍 400 万，
    /// 与实测吻合。两条独立观测都落在同一个点，所以基准就定 200 万。
    ///
    /// 现在 1× = 200 万条/秒 = 原机手感；1.5× 偏快、2× 就是当初那个「快得
    /// 离谱」的速度，留着当反面对照。
    public static let baseStepsPerSecond = 2_000_000.0

    /// 速度倍率的 UserDefaults 键。⚠️ `RootView` 的 `@AppStorage` 里写的是
    /// 同一个字面量，改这里必须同步改那边。
    ///
    /// 键名带 `bps` 是**故意的**：基准从 50 万改成 200 万后，老用户存着的
    /// `4.0` 会变成 800 万（4 倍于原机）。换一个键，旧值自然失效、回落到
    /// 缺省 1.0，不用写迁移代码，也不会有人莫名其妙被拉到 800 万。
    public static let speedKey = "bb.speed.bps"
    /// 倍率缺省值（1.0× = 上面那个基准）
    public static let speedDefault = 1.0
}

/// 高清（HD）模式。
///
/// 原 VM 的世界是 240×320 逻辑坐标，程序里所有坐标、字号、图片尺寸都按这套算。
/// HD 模式把**渲染画布**和**图片资源**同时放大 `scale` 倍，但对外（VM）仍报逻辑尺寸：
///   · 画布 240·s × 320·s
///   · 图片资源按 s 倍尺寸存放，`pictureWidth/Height` 仍返回原尺寸
///   · 文字按字号·s 栅格化，步进仍按字号算
/// 于是程序一行代码不用改，画面整体变成超采样；显示侧再缩回屏幕物理像素。
/// 资源缺失时 scale 保持 1，行为与原来完全一致。
///
/// **现状：开 3×**。倍率由 `MachineEngine.renderScale` 决定（改回 1 就是原版）。
/// 4× 之所以放弃，是因为 960 宽到屏幕 881 是**缩小**，要走面积平均，
/// 那一项桌面 CPU 实测 13.9ms/帧；3× 是放大，走最近邻查表，量级完全不同。
public enum BBHD {
    /// 倍率：1 = 原版 240×320，3 = 3× 超采样 720×960（见 `MachineEngine.renderScale`）
    public static var scale: Int = 1
    public static var isEnabled: Bool { scale > 1 }

    /// 把 VM 的逻辑坐标换算到画布像素
    @inline(__always) public static func px(_ v: Int) -> Int { v * scale }
    /// 把画布像素换算回 VM 的逻辑坐标
    @inline(__always) public static func logical(_ v: Int) -> Int { scale == 0 ? v : v / scale }
}

@inline(__always) public func bbSigned(_ v: UInt32) -> Int32 { Int32(bitPattern: v) }
@inline(__always) public func bbUnsigned(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }

/// 文件名大小写兜底。
///
/// iOS 的 APFS 默认**区分大小写**，而 BB 程序里写死的资源名（`RICH.LIB`、`SAVE.SAV`）
/// 和从 Windows / U 盘 / 网盘拷进来的实际文件名（`rich.lib`、`rich.Lib`）经常对不上。
/// 原 VM 跑在不区分大小写的文件系统上，从来没暴露过这个问题；
/// 到手机上就变成「目录里明明有文件，程序却读不到」—— 大富翁黑屏、存档读不回来都是这个原因。
///
/// 这里做的是**只在精确路径不存在时**才做一次大小写不敏感匹配；
/// 找不到仍返回原路径，让「新建文件」的语义保持不变。
public enum BBFileResolver {

    /// 「目录|想要的名字」→ 目录里的实际文件名。
    /// 只在**精确路径不存在**时才会查，所以文件名大小写对得上时完全不碰这里；
    /// 而一旦某个名字要兜底（比如 `RICH.LIB` vs `rich.lib`），
    /// 游戏每画一张图都会问一次 —— 不缓存就是每帧几十次目录遍历。
    private static var matchCache: [String: String] = [:]
    private static let lock = NSLock()

    /// 取 `dir/name`。名字对不上时按大小写不敏感找同一层里的实际文件名。
    public static func child(named name: String, in dir: URL) -> URL {
        let exact = dir.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: exact.path) { return exact }

        let key = dir.path + "|" + name
        lock.lock()
        let cached = matchCache[key]
        lock.unlock()
        if let cached {
            let hit = dir.appendingPathComponent(cached)
            if fm.fileExists(atPath: hit.path) { return hit }
        }

        guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
              let hit = items.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return exact }

        lock.lock()
        matchCache[key] = hit
        lock.unlock()
        return dir.appendingPathComponent(hit)
    }

    /// 相对路径（`sub/DIR/RICH.LIB`）→ 真实 URL，逐级做大小写兜底
    public static func url(forRelativePath path: String, root: URL) -> URL {
        var url = root
        for comp in path.split(separator: "/") where comp != "." && comp != ".." {
            url = child(named: String(comp), in: url)
        }
        return url
    }
}

/// 类 C 的 rand()：同一 seed 下可复现，方便和真机/PC 虚拟机对拍。
public final class BBCRandom {
    private var state: UInt64

    public init(seed: UInt32 = 1) {
        state = UInt64(seed == 0 ? 1 : seed)
    }

    public func srand(_ seed: UInt32) {
        state = UInt64(seed == 0 ? 1 : seed)
    }

    /// 返回 [0, 2^31) 的整数，等价于 C 的 rand()
    public func rand() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32((state >> 33) & 0x7FFF_FFFF)
    }
}

public enum GBKCodec {
    /// GB18030 编码（兼容 GBK/GB2312），iOS/macOS 走 CoreFoundation，其它平台降级
    public static func decode(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        if bytes.count == 1 { return String(UnicodeScalar(bytes[0])) }
        #if canImport(Darwin)
        let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: Data(bytes), encoding: String.Encoding(rawValue: cfEnc)) {
            return s
        }
        #endif
        if let s = String(data: Data(bytes), encoding: .isoLatin1) {
            return s
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        decode(Array(bytes))
    }

    /// 文件名等场景使用；编码失败时回退到 UTF-8。
    public static func encode(_ string: String) -> [UInt8] {
        #if canImport(Darwin)
        let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let d = string.data(using: String.Encoding(rawValue: cfEnc)) {
            return [UInt8](d)
        }
        #endif
        return [UInt8](string.utf8)
    }

    /// 按 GBK 规则切出一个字符的字节数：0x81...0xFE 开头视为双字节
    @inline(__always)
    public static func unitLength(_ bytes: [UInt8], at index: Int) -> Int {
        guard index < bytes.count else { return 0 }
        let b = bytes[index]
        if b >= 0x81 && b <= 0xFE && b != 0xFF && index + 1 < bytes.count {
            let b2 = bytes[index + 1]
            if b2 >= 0x40 && b2 <= 0xFE && b2 != 0x7F { return 2 }
        }
        return 1
    }
}

extension Array where Element == UInt8 {
    /// 截到第一个 0 为止
    public var bbZeroTerminated: [UInt8] {
        if let i = firstIndex(of: 0) { return Array(self[..<i]) }
        return self
    }
}

/// 颜色：内部统一 0xRRGGBB。原 VM 的颜色字在不同端口上含义不同（有的当 BGR，有的当 RGB），
/// 这些转换全部放在端口层还原，画布层只认 RGB。
@inline(__always) public func bbRGB(r: UInt32, g: UInt32, b: UInt32) -> UInt32 {
    ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
}

/// 原 VM 的 TRANS_COLOR_END：交换低字节与第 3 字节（R/B 互换）
@inline(__always) public func bbSwapRB(_ c: UInt32) -> UInt32 {
    ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
}
