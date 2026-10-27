//
//  BBVM.swift
//  BB9688
//
//  BBasic 字节码虚拟机（指令集 + 端口），逐条对应 bbasic/src/bbvm/bbvm.cc、inport.cc、outport.cc。
//  为保证老程序行为一致，保留了原实现的若干怪癖（例如 LD 的掩码语义、SHOWPIC 参数逆序、颜色 BGR/RGB 混用）。
//

import Dispatch
import Foundation

public final class BBVM {
    // 指令长度表，下标 = 高 4 位操作码
    private static let cmdLength: [Int] = [1, 10, 5, 5, 10, 10, 5, 6, 5, 1, 10, 10, 0, 0, 0, 1]
    // 数据类型 → 字节数
    private static let typeSize: [Int] = [4, 2, 1, 4, 4]

    enum R {
        static let rp = 0, rf = 1, rs = 2, rb = 3, r0 = 4, r1 = 5, r2 = 6, r3 = 7
    }

    enum DataType {
        static let dword = 0, word = 1, byte = 2, float = 3, int = 4
    }

    private enum Addr {
        static let reg = 0, regEx = 1, imm = 2, immEx = 3
    }

    private enum Flag {
        static let z = 1, b = 2, be = 3, a = 4, ae = 5, nz = 6
    }

    // MARK: - 组成

    public let memory: BBMemory
    public let strings = BBStringPool()
    public let screen: BBScreen
    public let graphics: BBGraphics
    public let storage: BBStorage
    public let input = BBInputQueue()
    let rng = BBCRandom()

    var regs = [UInt32](repeating: 0, count: 8)
    var dataPtr: UInt32 = 0

    public private(set) var stateBase = 0
    public private(set) var binVersion = 19
    public private(set) var isRunning = false
    public private(set) var exitReason: String?
    public private(set) var stepCount: UInt64 = 0

    public var frameHandler: (() -> Void)?
    public var exitHandler: (() -> Void)?
    public var logHandler: ((String) -> Void)?

    /// 金手指钩子：`OUT 33`（RND）的出口。
    ///
    /// 参数是「请求的上界 n」和「当前帧基址 rb」（调用方的返回地址在 `[rb+4]`，
    /// 见 `BBCheat.frameReturnAddress`）。返回非 nil 就用它替换随机结果。
    ///
    /// 唯独随机数留钩子，是因为**只有它无法从内存侧旁路**：骰子点数不进内存，
    /// 掷出来直接参与走位。其余（现金、股价）都是内存里的数组，直接读写即可。
    /// 默认 nil —— VM 主循环里只是多一次可选值判空。
    public var randomHook: ((_ n: UInt32, _ frameBase: UInt32) -> UInt32?)?

    public init(programDirectory: URL, textRenderer: BBTextRenderer) {
        memory = BBMemory()
        storage = BBStorage(root: programDirectory)
        screen = BBScreen(renderer: textRenderer)
        graphics = BBGraphics(root: programDirectory)
        graphics.screen = screen
        screen.frameHook = { [weak self] in self?.frameHandler?() }
    }

    // MARK: - 载入

    @discardableResult
    public func load(bin data: Data) -> Int {
        var bytes = [UInt8](data)
        var size = bytes.count
        if bytes.count >= 16, bytes[0] == 0x42, bytes[1] == 0x42, bytes[2] == 0x45 {  // "BBE"
            binVersion = bytes[7] == 0x40 ? 19 : 20
            bytes.removeFirst(16)
            size -= 16
        } else {
            binVersion = 19
        }
        memory.load(bytes)
        stateBase = size
        return size
    }

    /// 程序计数器（正在执行的那条指令的地址）。
    ///
    /// 只给诊断/探针用：从渲染器回调里读它，就能知道「这一笔是谁画的」，
    /// 从而定位到某个界面的绘制代码。VM 线程写、别的线程读，读到的可能是
    /// 下一条指令的地址 —— 对定位调用点足够。
    public var programCounter: UInt32 { regs[R.rp] }

    public func reset() {
        regs = [UInt32](repeating: 0, count: 8)
        regs[R.rb] = UInt32(truncatingIfNeeded: stateBase)
        regs[R.rs] = regs[R.rb] + UInt32(BBConst.stackSize)
        dataPtr = 0
        stepCount = 0
        exitReason = nil
        pendingCall = nil
        injectedCaller = nil
    }

    // MARK: - 注入调用

    /// 注入返回地址的哨兵。子程序的 `RET` 会把它弹回 rp，主循环看到它就收尾。
    /// 取值远离任何合法代码地址（内存 2MB），不可能被真的执行到。
    private static let injectionSentinel: UInt32 = 0xFFFF_FFF0

    private var pendingCall: UInt32?
    private var injectedCaller: [UInt32]?

    /// 请求在下一个指令边界**调用一次**子程序，返回后寄存器原样恢复。
    ///
    /// 用途：金手指改完钱，想让状态栏立刻显示新数字，但游戏只在「换人」时重绘它。
    /// 与其等下一回合，不如直接调一次游戏的绘制函数（`0x320BA`）。
    ///
    /// 安全性：
    ///  · 只在指令边界插入，不会打断某条指令；
    ///  · 用哨兵返回地址 + 全寄存器保存/恢复，对调用方完全透明；
    ///  · 目标函数应当是**只读绘制**（状态栏就是这么个函数）；
    ///  · 同一时刻只允许一个挂起请求，重复调用以最后一次为准。
    public func requestSubroutineCall(_ target: UInt32) {
        guard target > 0, target < UInt32(memory.size - 16) else { return }
        pendingCall = target
    }

    // MARK: - 运行

    public func run() {
        guard stateBase > 0 else {
            exitReason = "没有载入程序"
            exitHandler?()
            return
        }
        reset()
        isRunning = true

        // ── 节流：把执行挂到一条「虚拟时间轴」上 ──────────────────────────
        // 每 `quantum` 步把时间轴推进 quantum/rate 秒，跑快了就睡到那一刻。
        //
        // 三条规则，缺一条都会导致速率不准：
        //   1. 时间轴用**绝对**时间推进（target 累加），不是「睡固定时长」——
        //      系统把 3ms 睡成 4ms 时，下一片自然少睡一点补回来，误差不累积。
        //   2. `delay()` 这类「程序主动不执行」的时间要算进时间轴（`idleSeconds`），
        //      否则 `OUT 27` 睡完之后会猛跑一段把账补上，动画一顿一冲。
        //   3. 只有落后超过 0.2s（切后台、长时间阻塞）才重整时间轴，
        //      小落后允许追 —— 见下面 `-slack > 0.20`。
        let quantum = 2048
        var target = Self.clockSeconds()
        var sinceSync = 0
        idleSeconds = 0

        while isRunning {
            // ── 注入调用（金手指用）──────────────────────────────────
            // 先把「上一次注入跑完了没有」判掉，再决定要不要注入新的一次。
            // 哨兵地址故意取一个不可能执行的 pc：一旦 rp 变成它，就说明
            // 被调用的子程序 RET 回来了，把寄存器（含 rp）原样恢复。
            if let saved = injectedCaller {
                if rp == BBVM.injectionSentinel {
                    regs = saved
                    injectedCaller = nil
                    continue
                }
            } else if let target = pendingCall {
                pendingCall = nil
                injectedCaller = regs
                push(BBVM.injectionSentinel)
                regs[R.rp] = target
            }

            if !exec() { break }
            stepCount &+= 1
            sinceSync += 1

            if sinceSync >= quantum {
                sinceSync = 0
                let idle = idleSeconds
                idleSeconds = 0
                target += Double(quantum) / Self.ratePerSecond() + idle

                let t = Self.clockSeconds()
                let slack = target - t
                if slack > 0.0005 {
                    // 上限 4ms：一次睡太久，`IN 39` 之类的轮询就会变迟钝。
                    // 分片睡保证最迟 4ms 看一次输入状态。
                    Thread.sleep(forTimeInterval: min(slack, 0.004))
                } else if -slack > 0.20 {
                    // 已经落后 0.2s 以上：补跑没有意义（画面早追不上了），
                    // 直接对齐到现在，避免「卡一下然后猛冲」。
                    target = t
                }
                if input.isStopped || !isRunning { break }
            }
            if let fault = memory.fault {
                exitReason = fault
                break
            }
        }

        isRunning = false
        input.stop()
        exitHandler?()
    }

    /// 程序「不执行字节码」的时间（`OUT 27` 延时、阻塞读键等）。
    /// 由端口层累加，`run()` 在下一个节流片里把它算进时间轴 ——
    /// 这样延时之后不会出现「补跑风暴」。
    var idleSeconds: Double = 0

    // MARK: - 速度

    /// 速度倍率，由设置层写入（键见 `BBConst.speedKey`）。
    ///
    /// 每个节流片读一次，所以**玩到一半改速度也立刻生效**，不用重进游戏。
    /// 跨线程读写：写只发生在主线程、读在 VM 线程，Double 是 8 字节对齐的单次
    /// 读写，arm64 上不会读到半个值；最坏情况是晚一片生效，无所谓。
    public static var speedScale: Double = BBConst.speedDefault

    /// 从 UserDefaults 读一次倍率。启动程序前和 App 启动时各调一次，
    /// 保证「上次调好的速度」在没进设置页的情况下也生效。
    public static func loadSpeedFromDefaults() {
        let store = UserDefaults.standard
        if let v = store.object(forKey: BBConst.speedKey) as? Double, v > 0 {
            speedScale = v
        } else {
            speedScale = BBConst.speedDefault
        }
    }

    /// 当前目标速率（条/秒）= 基准 × 倍率
    private static func ratePerSecond() -> Double {
        let scale = speedScale > 0 ? speedScale : BBConst.speedDefault
        // 下限 5 万：再低连按键轮询都跟不上，程序会像死机
        return max(50_000.0, BBConst.baseStepsPerSecond * scale)
    }

    /// 单调时钟（秒）。不用 `Date()`：系统对时会跳变，时间轴会突然前移或倒流。
    static func clockSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public func stop() {
        isRunning = false
        input.stop()
        // 阻塞在端口里的线程会在 input.stop() 后立即返回
    }

    @discardableResult private func fault(_ message: String) -> Bool {
        exitReason = message
        isRunning = false
        return false
    }

    // MARK: - 内存/寄存器原语

    @inline(__always) private var rp: UInt32 { regs[R.rp] }
    @inline(__always) private var rf: UInt32 { regs[R.rf] }
    @inline(__always) private var rs: UInt32 { regs[R.rs] }
    @inline(__always) private var r0: UInt32 { regs[R.r0] }
    @inline(__always) private var r1: UInt32 { regs[R.r1] }
    @inline(__always) private var r2: UInt32 { regs[R.r2] }
    @inline(__always) private var r3: UInt32 { regs[R.r3] }

    @inline(__always) private func getReg(_ reg: Int) -> UInt32 {
        guard reg >= 0, reg < 8 else { return 0 }
        return regs[reg]
    }

    @inline(__always) private func putReg(_ reg: Int, _ value: UInt32, size: Int) {
        guard reg >= 0, reg < 8 else { return }
        let mask: UInt32 = size >= 4 ? 0xFFFF_FFFF : ((1 << (size * 8)) - 1)
        regs[reg] = (regs[reg] & ~mask) | (value & mask)
    }

    /// 读内存的旁路观察口（诊断用，默认 nil）。
    ///
    /// 参数是「读的地址」和「当时正在执行的 pc」。研究金手指时用它定位
    /// 「谁在读现金数组」—— 状态栏重绘必然要读它，画图和算账一眼分得开。
    /// VM 线程同步调用；生产环境保持 nil，只多一次判空。
    public var memReadHook: ((_ address: Int, _ pc: UInt32) -> Void)?

    func getMem(_ addr: UInt32) -> UInt32 {
        if let hook = memReadHook { hook(Int(addr), rp) }
        return memory.read32(Int(addr))
    }

    func putMem(_ addr: UInt32, _ value: UInt32, size: Int) {
        memory.write(Int(addr), value, sizeBytes: size)
    }

    private func getData(_ addressing: UInt8, _ argument: UInt32) -> UInt32 {
        switch addressing {
        case UInt8(Addr.reg):   return getReg(Int(argument))
        case UInt8(Addr.regEx): return getMem(getReg(Int(argument)))
        case UInt8(Addr.imm):   return argument
        case UInt8(Addr.immEx): return getMem(argument)
        default:                return 0
        }
    }

    private func putData(_ addressing: UInt8, _ argument: UInt32, _ value: UInt32, _ dataType: UInt8) {
        let size = dataType < 5 ? BBVM.typeSize[Int(dataType)] : 4
        switch addressing {
        case UInt8(Addr.reg):   putReg(Int(argument), value, size: size)
        case UInt8(Addr.regEx): putMem(getReg(Int(argument)), value, size: size)
        case UInt8(Addr.imm):   break
        case UInt8(Addr.immEx): putMem(argument, value, size: size)
        default:                break
        }
    }

    private func push(_ value: UInt32) {
        putData(UInt8(Addr.regEx), UInt32(R.rs), value, UInt8(DataType.dword))
        regs[R.rs] = regs[R.rs] &- 4
    }

    private func pop() -> UInt32 {
        regs[R.rs] = regs[R.rs] &+ 4
        return getData(UInt8(Addr.regEx), UInt32(R.rs))
    }

    private func getFlag(_ flag: UInt8) -> Bool {
        switch flag {
        case UInt8(Flag.nz): return (rf & UInt32(Flag.z)) == 0
        case UInt8(Flag.z):  return (rf & UInt32(Flag.z)) != 0
        case UInt8(Flag.be): return ((rf & UInt32(Flag.b)) | (rf & UInt32(Flag.z))) != 0
        case UInt8(Flag.b):  return (rf & UInt32(Flag.b)) != 0
        case UInt8(Flag.ae): return ((rf & UInt32(Flag.a)) | (rf & UInt32(Flag.z))) != 0
        case UInt8(Flag.a):  return (rf & UInt32(Flag.a)) != 0
        default:             return false
        }
    }

    private func putFlag(_ flag: UInt32) {
        regs[R.rf] = flag
    }

    // MARK: - 指令执行

    private func exec() -> Bool {
        let addr = Int(rp)
        guard addr >= 0, addr < memory.size - 10 else {
            return fault("程序计数器越界 0x\(String(addr, radix: 16))")
        }
        let byte0 = memory.read8(addr)
        let opcode = Int((byte0 & 0xF0) >> 4)
        let cmdLen = BBVM.cmdLength[opcode]
        guard cmdLen > 0 else { return fault("非法指令 0x\(String(byte0, radix: 16))") }

        var addressing: UInt8 = 0, addressingSec: UInt8 = 0
        var flag: UInt8 = 0, dataType: UInt8 = 0, calType: UInt8 = 0
        var arg: UInt32 = 0, argSec: UInt32 = 0

        switch cmdLen {
        case 1:
            break
        case 5:
            addressing = byte0 & 0x0F
            arg = memory.read32(addr + 1)
        case 6:
            flag = byte0 & 0x0F
            addressing = memory.read8(addr + 1)
            arg = memory.read32(addr + 2)
        case 10:
            dataType = byte0 & 0x0F
            guard dataType <= 4 else { return fault("未知数据类型 \(dataType)") }
            let byte1 = memory.read8(addr + 1)
            calType = (byte1 & 0xF0) >> 4
            addressing = byte1 & 0x0F
            addressingSec = addressing & 0x03
            addressing >>= 2
            arg = memory.read32(addr + 2)
            argSec = memory.read32(addr + 6)
        default:
            break
        }

        switch opcode {
        case 0x0:
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x1:   // LD
            putData(addressing, arg, getData(addressingSec, argSec), dataType)
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x2:   // PUSH
            push(getData(addressing, arg))
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x3:   // POP
            putData(addressing, arg, pop(), dataType)
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x4:   // IN
            putData(addressing, arg, inPort(getData(addressingSec, argSec)), dataType)
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x5:   // OUT
            outPort(getData(addressing, arg), getData(addressingSec, argSec))
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0x6:   // JMP
            regs[R.rp] = getData(addressing, arg)
        case 0x7:   // JPC
            if getFlag(flag) {
                regs[R.rp] = getData(addressing, arg)
            } else {
                regs[R.rp] = rp &+ UInt32(cmdLen)
            }
        case 0x8:   // CALL
            push(rp &+ UInt32(cmdLen))
            regs[R.rp] = getData(addressing, arg)
        case 0x9:   // RET
            regs[R.rp] = pop()
        case 0xA:   // CMP
            compare(dataType: dataType, lhs: getData(addressing, arg), rhs: getData(addressingSec, argSec))
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0xB:   // CAL
            let result = calculate(dataType: dataType, calType: calType,
                                   lhs: getData(addressing, arg), rhs: getData(addressingSec, argSec))
            putData(addressing, arg, result, dataType)
            regs[R.rp] = rp &+ UInt32(cmdLen)
        case 0xF:   // EXIT
            exitReason = "程序正常退出"
            isRunning = false
            return false
        default:
            return fault("未知指令 0x\(String(opcode, radix: 16)) @0x\(String(addr, radix: 16))")
        }

        return isRunning
    }

    private func compare(dataType: UInt8, lhs: UInt32, rhs: UInt32) {
        var a = bbSigned(lhs)
        var b = bbSigned(rhs)
        switch dataType {
        case UInt8(DataType.byte):
            a &= 0xFF; b &= 0xFF
            fallthrough
        case UInt8(DataType.word):
            a &= 0xFFFF; b &= 0xFFFF
            fallthrough
        case UInt8(DataType.dword), UInt8(DataType.int):
            if a == b { putFlag(UInt32(Flag.z)) }
            else if a < b { putFlag(UInt32(Flag.b)) }
            else { putFlag(UInt32(Flag.a)) }
        case UInt8(DataType.float):
            let fa = Float(bitPattern: lhs), fb = Float(bitPattern: rhs)
            if fa == fb { putFlag(UInt32(Flag.z)) }
            else if fa < fb { putFlag(UInt32(Flag.b)) }
            else { putFlag(UInt32(Flag.a)) }
        default:
            break
        }
    }

    private func calculate(dataType: UInt8, calType: UInt8, lhs: UInt32, rhs: UInt32) -> UInt32 {
        var a = bbSigned(lhs)
        var b = bbSigned(rhs)
        switch dataType {
        case UInt8(DataType.byte):
            a &= 0xFF; b &= 0xFF
            fallthrough
        case UInt8(DataType.word):
            a &= 0xFFFF; b &= 0xFFFF
            fallthrough
        case UInt8(DataType.dword), UInt8(DataType.int):
            let result: Int32
            switch calType {
            case 0: result = a &+ b
            case 1: result = a &- b
            case 2: result = a &* b
            case 3: result = b == 0 ? 0 : a / b
            case 4: result = b == 0 ? 0 : a % b
            default: result = 0
            }
            return bbUnsigned(result)
        case UInt8(DataType.float):
            let fa = Float(bitPattern: lhs), fb = Float(bitPattern: rhs)
            let result: Float
            switch calType {
            case 0: result = fa + fb
            case 1: result = fa - fb
            case 2: result = fa * fb
            case 3: result = fb == 0 ? 0 : fa / fb
            default: result = 0
            }
            return result.bitPattern
        default:
            return 0
        }
    }
}
