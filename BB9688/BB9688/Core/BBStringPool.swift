//
//  BBStringPool.swift
//  BB9688
//
//  BB 的字符串句柄池：句柄从 -1 开始向下分配，内容为 GBK 字节。
//

import Foundation

public final class BBStringPool {
    private var pool: [[UInt8]?] = []

    public init() {}

    public func create() -> UInt32 {
        if let idx = pool.firstIndex(where: { $0 == nil }) {
            pool[idx] = []
            return UInt32(bitPattern: -Int32(idx + 1))
        }
        pool.append([])
        return UInt32(bitPattern: -Int32(pool.count))
    }

    public func isEffective(_ handle: UInt32) -> Bool {
        let raw = bbSigned(handle)
        guard raw < 0 else { return false }
        let idx = Int(-raw) - 1
        guard idx >= 0, idx < pool.count else { return false }
        return pool[idx] != nil
    }

    public func get(_ handle: UInt32) -> [UInt8] {
        guard isEffective(handle) else { return [] }
        return pool[Int(-bbSigned(handle)) - 1] ?? []
    }

    public func put(_ handle: UInt32, _ bytes: [UInt8]) {
        guard isEffective(handle) else { return }
        pool[Int(-bbSigned(handle)) - 1] = bytes
    }

    public func append(_ handle: UInt32, _ bytes: [UInt8]) {
        guard isEffective(handle) else { return }
        pool[Int(-bbSigned(handle)) - 1]?.append(contentsOf: bytes)
    }

    public func free(_ handle: UInt32) {
        guard isEffective(handle) else { return }
        pool[Int(-bbSigned(handle)) - 1] = nil
    }
}
