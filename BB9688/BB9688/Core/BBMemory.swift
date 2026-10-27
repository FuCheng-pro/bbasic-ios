//
//  BBMemory.swift
//  BB9688
//
//  2MB 线性内存。原 VM 大量使用 *(int*)(vmem+addr) 做非对齐读写，
//  这里用 loadUnaligned/storeBytes 复刻同样的语义（小端），越界不崩溃而是钳制并记录故障。
//

import Foundation

public final class BBMemory {
    public let size: Int
    private let base: UnsafeMutableRawPointer
    public private(set) var fault: String?

    public init(size: Int = BBConst.memorySize) {
        self.size = size
        base = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    }

    deinit {
        base.deallocate()
    }

    @inline(__always) private func check(_ addr: Int, _ len: Int) -> Bool {
        if addr < 0 || addr + len > size {
            if fault == nil { fault = "内存访问越界 0x\(String(addr, radix: 16)) (+\(len))" }
            return false
        }
        return true
    }

    @inline(__always) public func read8(_ addr: Int) -> UInt8 {
        guard check(addr, 1) else { return 0 }
        return base.load(fromByteOffset: addr, as: UInt8.self)
    }

    @inline(__always) public func read16(_ addr: Int) -> UInt16 {
        guard check(addr, 2) else { return 0 }
        return base.loadUnaligned(fromByteOffset: addr, as: UInt16.self)
    }

    @inline(__always) public func read32(_ addr: Int) -> UInt32 {
        guard check(addr, 4) else { return 0 }
        return base.loadUnaligned(fromByteOffset: addr, as: UInt32.self)
    }

    @inline(__always) public func write8(_ addr: Int, _ value: UInt8) {
        guard check(addr, 1) else { return }
        base.storeBytes(of: value, toByteOffset: addr, as: UInt8.self)
    }

    /// 按原 VM 的掩码语义写入：只覆盖低 size 字节，高字节保持原值
    @inline(__always) public func write(_ addr: Int, _ value: UInt32, sizeBytes: Int) {
        switch sizeBytes {
        case 1:
            write8(addr, UInt8(value & 0xFF))
        case 2:
            // 原 VM 的 Mask 由「字节数」推出：Size=2 → 低 16 位整体覆盖。
            // 早期版本这里误写成 (old & 0xFF00) | UInt16(value & 0xFF)，
            // 只覆盖低 8 位、高 8 位保留旧值，会把 word 写坏成两个字节的拼接。
            guard check(addr, 2) else { return }
            base.storeUnalignedBytes(of: UInt16(truncatingIfNeeded: value),
                                     toByteOffset: addr)
        default:
            guard check(addr, 4) else { return }
            base.storeUnalignedBytes(of: value, toByteOffset: addr)
        }
    }

    public func load(_ data: [UInt8], at offset: Int = 0) {
        guard offset >= 0, offset + data.count <= size else { return }
        data.withUnsafeBytes { raw in
            if let p = raw.baseAddress {
                base.advanced(by: offset).copyMemory(from: p, byteCount: data.count)
            }
        }
    }

    public func bytes(at offset: Int, count: Int) -> [UInt8] {
        guard offset >= 0, count > 0, offset + count <= size else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        out.withUnsafeMutableBytes { raw in
            if let p = raw.baseAddress {
                p.copyMemory(from: base.advanced(by: offset), byteCount: count)
            }
        }
        return out
    }

    /// 读 C 字符串（到 0 结束），最多 limit 字节
    public func cString(at addr: Int, limit: Int = 0x10000) -> [UInt8] {
        guard addr >= 0, addr < size else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        var p = addr
        let end = min(size, addr + limit)
        while p < end {
            let b = base.load(fromByteOffset: p, as: UInt8.self)
            if b == 0 { break }
            out.append(b)
            p += 1
        }
        return out
    }

    public func writeBytes(_ bytes: [UInt8], at addr: Int) {
        guard addr >= 0, addr + bytes.count <= size else { return }
        bytes.withUnsafeBytes { raw in
            if let p = raw.baseAddress {
                base.advanced(by: addr).copyMemory(from: p, byteCount: bytes.count)
            }
        }
    }
}

private extension UnsafeMutableRawPointer {
    @inline(__always) func storeUnalignedBytes(of value: UInt32, toByteOffset offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { raw in
            if let p = raw.baseAddress {
                advanced(by: offset).copyMemory(from: p, byteCount: 4)
            }
        }
    }

    @inline(__always) func storeUnalignedBytes(of value: UInt16, toByteOffset offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { raw in
            if let p = raw.baseAddress {
                advanced(by: offset).copyMemory(from: p, byteCount: 2)
            }
        }
    }
}
