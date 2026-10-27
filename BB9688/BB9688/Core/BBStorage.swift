//
//  BBStorage.swift
//  BB9688
//
//  BB 的文件端口（48~55）。原实现直接 fopen 相对路径，这里把所有相对路径钉到
//  「程序工作目录」，并把内容缓存在 Data 中，读写后落盘。
//
//  注意偏移语义：原 VM 的 fseek(Offset - 0x7FFFFFFF, SEEK_CUR)，
//  即 0x7FFFFFFF 表示「当前位置」，其余为相对偏移。
//

import Foundation

public final class BBStorage {
    public let root: URL
    private var files: [Int: OpenFile] = [:]

    private final class OpenFile {
        let url: URL
        var data: Data
        var pos: Int = 0
        var dirty = false
        init(url: URL, data: Data) {
            self.url = url
            self.data = data
        }
    }

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// GBK 文件名 → 本地 URL（限制在 root 内，防止路径穿越）
    ///
    /// 逐级走 `BBFileResolver`：iOS 区分大小写，程序里写 `RICH.LIB`、
    /// 实际文件叫 `rich.lib` 的时候，以前会直接当成「文件不存在」，
    /// 于是 fopen 建出一个空的 `RICH.LIB`，读出来全是 0。
    public func resolve(_ nameBytes: [UInt8]) -> URL {
        var name = GBKCodec.decode(nameBytes)
        name = name.replacingOccurrences(of: "\\", with: "/")
        while name.hasPrefix("/") { name.removeFirst() }
        return BBFileResolver.url(forRelativePath: name, root: root)
    }

    public func openFile(_ nameBytes: [UInt8], handle: Int) {
        closeFile(handle)
        let url = resolve(nameBytes)
        let fm = FileManager.default
        var data = Data()
        if let existing = try? Data(contentsOf: url) {
            data = existing
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 旧 SDK 返回 Bool、新 SDK 返回 Void，显式丢弃两种都干净
            _ = fm.createFile(atPath: url.path, contents: Data())
        }
        files[handle] = OpenFile(url: url, data: data)
    }

    public func closeFile(_ handle: Int) {
        guard let file = files[handle] else { return }
        flush(file)
        files[handle] = nil
    }

    public func closeAll() {
        for (_, file) in files { flush(file) }
        files.removeAll()
    }

    private func flush(_ file: OpenFile) {
        guard file.dirty else { return }
        try? file.data.write(to: file.url, options: .atomic)
        file.dirty = false
    }

    private func seek(_ file: OpenFile, delta: Int) {
        let target = file.pos + delta
        file.pos = max(0, min(file.data.count, target))
    }

    public func readInt(_ handle: Int, offset: Int) -> UInt32 {
        guard let file = files[handle] else { return 0 }
        seek(file, delta: offset - 0x7FFFFFFF)
        guard file.pos + 4 <= file.data.count else { return 0 }
        let bytes = [UInt8](file.data[file.pos..<file.pos + 4])
        file.pos += 4
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    public func readFloat(_ handle: Int, offset: Int) -> Float {
        Float(bitPattern: readInt(handle, offset: offset))
    }

    public func readString(_ handle: Int, offset: Int) -> [UInt8] {
        guard let file = files[handle] else { return [] }
        seek(file, delta: offset - 0x7FFFFFFF)
        var out: [UInt8] = []
        while file.pos < file.data.count {
            let b = file.data[file.pos]
            file.pos += 1
            if b == 0 { break }
            if b != 0xFF { out.append(b) }
        }
        return out
    }

    public func writeInt(_ handle: Int, offset: Int, value: UInt32) {
        guard let file = files[handle] else { return }
        seek(file, delta: offset - 0x7FFFFFFF)
        var data = file.data
        if file.pos + 4 > data.count {
            data.append(contentsOf: [UInt8](repeating: 0, count: file.pos + 4 - data.count))
        }
        let bytes: [UInt8] = [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
        data.replaceSubrange(file.pos..<file.pos + 4, with: bytes)
        file.pos += 4
        file.data = data
        file.dirty = true
    }

    public func writeString(_ handle: Int, offset: Int, bytes: [UInt8]) {
        guard let file = files[handle] else { return }
        seek(file, delta: offset - 0x7FFFFFFF)
        var data = file.data
        if file.pos > data.count {
            data.append(contentsOf: [UInt8](repeating: 0, count: file.pos - data.count))
        }
        let payload = bytes + [0]
        if file.pos + payload.count > data.count {
            data.append(contentsOf: [UInt8](repeating: 0, count: file.pos + payload.count - data.count))
        }
        data.replaceSubrange(file.pos..<file.pos + payload.count, with: payload)
        file.pos += payload.count
        file.data = data
        file.dirty = true
    }

    public func eof(_ handle: Int) -> Bool {
        guard let file = files[handle] else { return true }
        return file.pos >= file.data.count
    }

    public func size(_ handle: Int) -> UInt32 {
        guard let file = files[handle] else { return 0 }
        return UInt32(file.data.count)
    }

    public func position(_ handle: Int) -> UInt32 {
        guard let file = files[handle] else { return 0 }
        return UInt32(file.pos)
    }

    public func movePosition(_ handle: Int, to position: Int) {
        guard let file = files[handle] else { return }
        file.pos = max(0, min(file.data.count, position))
    }
}
