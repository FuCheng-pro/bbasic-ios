//
//  BBPerf.swift
//  BB9688
//
//  运行监控的**采样层**：只读自己进程的 mach 计数器，不碰 UI、不改任何行为。
//
//  为什么要在 App 里自己做：
//    · 本机是 Windows + xtool 自签路线，拿不到 Mac 上的 Instruments / Xcode 看板；
//    · iOS 没有公开的「设备温度」接口，官方能拿到的只有 `thermalState` 四级；
//    · 所以把「谁在烧 CPU」的答案交给 App 自己：进程总 CPU、主线程、VM 线程
//      分别是多少，内存、热状态一起打出来。
//
//  关键点：**分线程 CPU 用的是内核的衰减平均**（`thread_basic_info.cpu_usage`），
//  读到的是瞬时占用而不是累计值，所以不需要两次差分，单核满载就是 100%。
//
//  ⚠️ 这里只允许 Foundation + Darwin。Core 目录要求「与 UI 无关、可在 PC 上编译」。
//

import Darwin
import Foundation

// MARK: - 一次采样

public struct BBPerfSample {
    /// 整个进程的 CPU 占用（各线程相加，单核满载 = 100%，多核可能 > 100%）
    public var cpuProcess: Double = 0
    /// 主线程（UI / 帧泵 / 渲染编码）—— 采样必须在主线程调用才能取到
    public var cpuMain: Double = -1
    /// 虚拟机线程。-1 = 还没注册或线程已退出
    public var cpuMachine: Double = -1
    /// VM 线程当前是否在 RUNNING（而不是等锁/睡眠）
    public var machineRunning = false
    /// 进程线程数
    public var threadCount = 0
    /// 物理内存占用（phys_footprint）
    public var footprintMB: Double = 0
    /// 热状态中文名：正常 / 偏热 / 过热 / 极热
    public var thermal = "正常"
    /// `ProcessInfo.ThermalState` 原始值，0=nominal 1=fair 2=serious 3=critical
    public var thermalRaw = 0
    /// 低电量模式（此时系统会主动降频，帧率和 CPU 都会掉）
    public var lowPower = false
}

// MARK: - 采样器

public final class BBPerfSampler {

    public static let shared = BBPerfSampler()

    private let lock = NSLock()
    /// VM 线程的 mach port。由 VM 线程自己在启动时登记 ——
    /// `task_threads` 只给 port，不给名字，这是唯一能把那一条认出来的办法。
    private var machinePort: mach_port_t = 0

    /// `THREAD_RUNNING` 在 `mach/thread_info.h` 里是 `#define THREAD_RUNNING 2`。
    /// `THREAD_BASIC_INFO` / `TH_USAGE_SCALE` 这些宏 Clang 都导进了 Swift，
    /// 唯独 run_state 这一组没有 —— 直接写名字会
    /// `cannot find 'THREAD_RUNNING' in scope`（2026-10-26 真机编译实测）。
    /// 值就是 2（1=WAITING 2=RUNNING 3=UNINTERRUPTIBLE），自己钉一个常量。
    private static let threadRunningState: Int32 = 2

    public init() {}

    /// VM 线程启动时调一次（在那条线程内部调）
    public func registerMachineThread() {
        let port = pthread_mach_thread_np(pthread_self())
        lock.lock()
        machinePort = port
        lock.unlock()
    }

    /// VM 线程退出时调（可以在任意线程调，只清标记）
    public func unregisterMachineThread() {
        lock.lock()
        machinePort = 0
        lock.unlock()
    }

    /// 采一次。**在主线程调用**才能填上 `cpuMain`。
    public func sample() -> BBPerfSample {
        var out = BBPerfSample()

        lock.lock()
        let vmPort = machinePort
        lock.unlock()

        // 这里刻意写完整的 `UnsafeMutablePointer<thread_act_t>?` 而不是 `thread_act_array_t?`：
        // 后者本身是个 IUO 别名，再叠一层 `?` 在不同 Swift 版本里解释不一致。
        var list: UnsafeMutablePointer<thread_act_t>?
        var count: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list {
            out.threadCount = Int(count)
            let mainPort: mach_port_t = Thread.isMainThread
                ? pthread_mach_thread_np(pthread_self())
                : 0

            for i in 0..<Int(count) {
                let thread = list[i]
                var info = thread_basic_info()
                var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                let kr = withUnsafeMutablePointer(to: &info) { raw in
                    raw.withMemoryRebound(to: integer_t.self,
                                          capacity: Int(THREAD_INFO_MAX)) { buf in
                        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), buf, &infoCount)
                    }
                }
                guard kr == KERN_SUCCESS else { continue }

                let cpu = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
                out.cpuProcess += cpu
                if mainPort != 0, thread == mainPort {
                    out.cpuMain = cpu
                }
                if vmPort != 0, thread == vmPort {
                    out.cpuMachine = cpu
                    out.machineRunning = (info.run_state == Self.threadRunningState)
                }
            }

            // task_threads 给的是调用方负责释放的 vm 区，不释放就是每次采样泄漏
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(list))),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }

        // 内存：phys_footprint 才是「设置里看到的那个数」，resident_size 会虚高
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let memKR = withUnsafeMutablePointer(to: &vmInfo) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { buf in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), buf, &vmCount)
            }
        }
        if memKR == KERN_SUCCESS {
            out.footprintMB = Double(vmInfo.phys_footprint) / 1_048_576
        }

        // 热状态。iOS 只有这四级，没有温度数值 —— 它同时也是系统降频的判据：
        // 一旦进 serious/critical，SoC 已经在限频，这时候掉帧不一定是代码问题。
        let process = ProcessInfo.processInfo
        out.lowPower = process.isLowPowerModeEnabled
        out.thermalRaw = process.thermalState.rawValue
        switch process.thermalState {
        case .nominal:  out.thermal = "正常"
        case .fair:     out.thermal = "偏热"
        case .serious:  out.thermal = "过热"
        case .critical: out.thermal = "极热"
        @unknown default: out.thermal = "未知"
        }

        return out
    }
}
