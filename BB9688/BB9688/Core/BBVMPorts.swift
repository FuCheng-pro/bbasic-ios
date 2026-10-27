//
//  BBVMPorts.swift
//  BB9688
//
//  BB 的系统调用端口（IN 0~39 / OUT 0~80），逐条对齐 inport.cc 与 outport.cc。
//

import Foundation

enum BBCString {
    static func atoi(_ bytes: [UInt8]) -> Int32 {
        var i = 0
        while i < bytes.count, bytes[i] == 32 || (bytes[i] >= 9 && bytes[i] <= 13) { i += 1 }
        var sign: Int32 = 1
        if i < bytes.count, bytes[i] == 45 { sign = -1; i += 1 }
        else if i < bytes.count, bytes[i] == 43 { i += 1 }
        var value: Int64 = 0
        while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 {
            value = value * 10 + Int64(bytes[i] - 48)
            if value > 2_147_483_647 { value = 2_147_483_647 }
            i += 1
        }
        return Int32(sign * Int32(value))
    }

    static func atof(_ bytes: [UInt8]) -> Double {
        var text = ""
        for b in bytes {
            if (b >= 48 && b <= 57) || b == 43 || b == 45 || b == 46 || b == 101 || b == 69 {
                text.append(Character(UnicodeScalar(b)))
            } else if b == 32 {
                continue
            } else {
                break
            }
        }
        return Double(text) ?? 0
    }

    static func strcmp(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] {
            return Int32(a[i]) - Int32(b[i])
        }
        return Int32(a.count) - Int32(b.count)
    }
}

extension BBVM {
    // MARK: - 字符串工具

    func ioString(_ handle: UInt32) -> [UInt8] {
        if strings.isEffective(handle) { return strings.get(handle) }
        let address = Int(handle)
        guard address >= 0, address < memory.size else { return [] }
        return memory.cString(at: address)
    }

    private func putString(_ handle: UInt32, _ bytes: [UInt8]) {
        strings.put(handle, bytes)
    }

    private func stringHandle(_ bytes: [UInt8]) -> UInt32 {
        let handle = strings.create()
        strings.put(handle, bytes)
        return handle
    }

    // MARK: - IN 端口

    func inPort(_ port: UInt32) -> UInt32 {
        let r3Value = regs[R.r3]
        switch port {
        case 0:     // float -> int（截断取整，NaN/溢出钳制，避免崩溃）
            let f = Float(bitPattern: r3Value)
            guard f.isFinite else { return 0 }
            // 边界比较放到 Double 里做：Int32 的边界在 Double 中可精确表示，
            // 而 Float32 在 2^24 以上步长是 256，同量级的整数字面量无法精确表示
            // （会触发 "not exactly representable as 'Float'" 警告），
            // 且拿它当阈值还会在 Int32(f) 处留下越界陷阱的缺口。
            if Double(f) >= Double(Int32.max) { return bbUnsigned(Int32.max) }
            if Double(f) <= Double(Int32.min) { return bbUnsigned(Int32.min) }
            return bbUnsigned(Int32(f))
        case 1:     // int -> float
            // 必须按有符号解释：BB 的整数是 32 位有符号，
            // 0xFFFFFFFF 应当变成 -1.0 而不是 4294967296.0。
            // 参考实现的 inport.cc 这里写的是 (float)this->r3（无符号），
            // 但同一份代码里 Port 0 的 float->int、Port 4/32 的 int->string
            // 都实际走有符号，只有这一处是无符号 —— 是笔误。
            // 按无符号算会让 系数×(-1) 变成 系数×2^32，把浮点指数抬 32 位，
            // 大富翁股市页的「浮动系数」因此变成 1e10 级巨值，
            // 再转 int 就钳成 2147483647。
            return Float(Int32(bitPattern: r3Value)).bitPattern
        case 2:     // 申请字符串句柄
            return strings.create()
        case 3:     // 字符串 -> int
            return bbUnsigned(BBCString.atoi(ioString(r3Value)))
        case 4:     // int -> 字符串（写入 r2）
            putString(regs[R.r2], Array("\(bbSigned(r3Value))".utf8))
            return regs[R.r2]
        case 5:     // 复制字符串 r2 -> r3
            putString(r3Value, ioString(regs[R.r2]))
            return r3Value
        case 6:     // 连接字符串
            strings.append(r3Value, ioString(regs[R.r2]))
            return r3Value
        case 7:     // 长度
            return UInt32(ioString(r3Value).count)
        case 8:     // 释放
            strings.free(r3Value)
            return r3Value
        case 9:     // 比较
            return bbUnsigned(BBCString.strcmp(ioString(r3Value), ioString(regs[R.r2])))
        case 10:    // (int)r3 -> float -> 字符串。同样按有符号解释
            putString(regs[R.r2], Array(String(format: "%f", Float(Int32(bitPattern: r3Value))).utf8))
            return regs[R.r2]
        case 11:    // 字符串 -> float
            return Float(BBCString.atof(ioString(r3Value))).bitPattern
        case 12:    // 取字符
            let bytes = ioString(r3Value)
            let index = Int(regs[R.r2])
            guard index >= 0, index < bytes.count else { return 0 }
            return UInt32(bytes[index])
        case 13:    // 改字符
            var bytes = ioString(r3Value)
            let index = Int(regs[R.r2])
            if index >= 0, index < bytes.count {
                bytes[index] = UInt8(regs[R.r1] & 0xFF)
                putString(r3Value, bytes)
            }
            return r3Value
        case 14:
            return 65536
        case 15:    // 毫秒时钟
            let now = Date().timeIntervalSince1970 * 1000
            return UInt32(UInt64(now) % 1_000_000_000)
        case 16:
            return sinf(Float(bitPattern: r3Value)).bitPattern
        case 17:
            return cosf(Float(bitPattern: r3Value)).bitPattern
        case 18:
            return tanf(Float(bitPattern: r3Value)).bitPattern
        case 19:
            return sqrtf(Float(bitPattern: r3Value)).bitPattern
        case 20:
            let value = bbSigned(r3Value)
            return bbUnsigned(value == Int32.min ? Int32.max : abs(value))
        case 21:
            return fabsf(Float(bitPattern: r3Value)).bitPattern
        case 22:    // 重定位数据指针
            dataPtr = regs[R.r2]
            return r3Value
        case 23:
            return getMem(r3Value)
        case 24:
            putMem(r3Value, regs[R.r2], size: 4)
            return r3Value
        case 25:    // 机型环境值：9388.0
            return Float(9388.0).bitPattern
        case 32:    // r1 -> 字符串 r3
            putString(r3Value, Array("\(bbSigned(regs[R.r1]))".utf8))
            return r3Value
        case 33:
            return bbUnsigned(BBCString.atoi(ioString(r3Value)))
        case 34:
            let bytes = ioString(r3Value)
            return bytes.isEmpty ? 0 : UInt32(bytes[0])
        case 35:    // LEFT$
            let bytes = ioString(regs[R.r2])
            let size = Int(regs[R.r1])
            putString(r3Value, Array(bytes.prefix(max(0, size))))
            return r3Value
        case 36:    // RIGHT$
            let bytes = ioString(regs[R.r2])
            let size = Int(regs[R.r1])
            putString(r3Value, Array(bytes.suffix(max(0, size))))
            return r3Value
        case 37:    // MID$
            let bytes = ioString(regs[R.r2])
            let offset = max(0, Int(regs[R.r1]))
            let size = max(0, Int(regs[R.r0]))
            let tail = offset < bytes.count ? Array(bytes[offset...]) : []
            putString(r3Value, Array(tail.prefix(size)))
            return r3Value
        case 38:    // INSTR
            let master = ioString(r3Value)
            let sub = ioString(regs[R.r2])
            let offset = max(0, Int(regs[R.r1]))
            guard !sub.isEmpty, offset <= master.count else { return 0 }
            var index = offset
            while index + sub.count <= master.count {
                if Array(master[index..<(index + sub.count)]) == sub {
                    return UInt32(index)
                }
                index += 1
            }
            return 0
        case 39:
            return UInt32(ioString(r3Value).count)
        default:
            return 0
        }
    }

    // MARK: - OUT 端口

    func outPort(_ port: UInt32, _ argu: UInt32) {
        switch port {
        case 0:
            screen.displayNumber(bbSigned(argu))
            screen.newLine()
        case 1:
            screen.display(ioString(argu))
            screen.newLine()
        case 2:
            screen.display(ioString(argu))
        case 3:
            screen.displayNumber(bbSigned(argu))
        case 4:
            screen.display([UInt8(argu & 0xFF)])
        case 5:
            screen.displayFloat(Float(bitPattern: argu))
        case 10:    // INPUT 整数
            regs[R.r3] = bbUnsigned(BBCString.atoi(readLineInput()))
        case 11:    // INPUT 字符串
            putString(regs[R.r3], readLineInput())
        case 12:    // INPUT 浮点
            regs[R.r3] = Float(BBCString.atof(readLineInput())).bitPattern
        case 13:    // READ 整数
            regs[R.r3] = getMem(dataPtr)
            dataPtr = dataPtr &+ 4
        case 14:    // READ 字符串
            let bytes = ioString(dataPtr)
            dataPtr = dataPtr &+ UInt32(bytes.count + 1)
            putString(regs[R.r3], bytes)
        case 15:    // READ 浮点
            regs[R.r3] = getMem(dataPtr)
            dataPtr = dataPtr &+ 4
        case 16:
            screen.setSize(width: Int(regs[R.r2]), height: Int(regs[R.r3]))
        case 17:
            regs[R.r3] = bbUnsigned(Int32(graphics.allocSurface()))
        case 18:
            graphics.freeSurface(Int(bbSigned(regs[R.r3])))
        case 19:
            let handle = graphics.loadPicture(name: ioString(regs[R.r3]), index: Int(regs[R.r2]))
            regs[R.r3] = bbUnsigned(Int32(handle))
        case 20:    // SHOWPIC
            graphics.drawPicture(page: signedMem(regs[R.r3] + 32),
                                 pic: signedMem(regs[R.r3] + 28),
                                 dx: signedMem(regs[R.r3] + 24),
                                 dy: signedMem(regs[R.r3] + 20),
                                 w: signedMem(regs[R.r3] + 16),
                                 h: signedMem(regs[R.r3] + 12),
                                 x: signedMem(regs[R.r3] + 8),
                                 y: signedMem(regs[R.r3] + 4),
                                 mode: signedMem(regs[R.r3]))
        case 21:
            graphics.cloneSurface(src: Int(bbSigned(regs[R.r3])), dst: -1, x: 0, y: 0)
        case 22:
            graphics.cloneSurface(src: Int(bbSigned(regs[R.r3])), dst: Int(bbSigned(regs[R.r2])), x: 0, y: 0)
        case 23:    // FILLPAGE
            graphics.fillSurface(signedMem(regs[R.r3] + 20),
                                 x: signedMem(regs[R.r3] + 16),
                                 y: signedMem(regs[R.r3] + 12),
                                 w: signedMem(regs[R.r3] + 8),
                                 h: signedMem(regs[R.r3] + 4),
                                 color: getMem(regs[R.r3]))
        case 24:    // PIXEL
            graphics.writePixel(signedMem(regs[R.r3] + 12),
                                x: signedMem(regs[R.r3] + 8),
                                y: signedMem(regs[R.r3] + 4),
                                color: getMem(regs[R.r3]))
        case 25:    // READPIXEL
            regs[R.r3] = graphics.readPixel(signedMem(regs[R.r3] + 8),
                                            x: signedMem(regs[R.r3] + 4),
                                            y: signedMem(regs[R.r3]))
        case 26:
            graphics.freePicture(Int(bbSigned(regs[R.r3])))
        case 27:
            delay(milliseconds: Int(regs[R.r3]))
        case 32:
            rng.srand(regs[R.r3])
        case 33:
            // 金手指可以改写骰子点数。钩子为 nil 时行为与原来完全一致。
            if let hook = randomHook, let forced = hook(regs[R.r3], regs[R.rb]) {
                regs[R.r3] = forced
            } else {
                regs[R.r3] = regs[R.r3] == 0 ? 0 : rng.rand() % regs[R.r3]
            }
        case 34:
            regs[R.r3] = input.keyPressed(regs[R.r3]) ? 1 : 0
        case 35:
            screen.clear()
        case 36:
            screen.setTextLocation(row: Int(regs[R.r2]), column: Int(regs[R.r3]))
        case 37:
            screen.setTextColor(front: getMem(regs[R.r3] + 8), back: getMem(regs[R.r3] + 4))
        case 38:
            screen.setFont(Int(regs[R.r3]))
        case 39:
            regs[R.r3] = waitKey()
        case 40:
            regs[R.r3] = UInt32(graphics.pictureWidth(Int(bbSigned(regs[R.r3]))))
        case 41:
            regs[R.r3] = UInt32(graphics.pictureHeight(Int(bbSigned(regs[R.r3]))))
        case 42:
            screen.setDispPosition(x: Int(regs[R.r2]), y: Int(regs[R.r3]))
        case 43:
            graphics.cloneSurface(src: signedMem(regs[R.r3]),
                                  dst: signedMem(regs[R.r3] + 4),
                                  x: signedMem(regs[R.r3] + 12),
                                  y: signedMem(regs[R.r3] + 8))
        case 44:
            screen.transparent = regs[R.r3] == 1
        case 45:    // InKey$
            let key = waitKey()
            putString(regs[R.r3], [UInt8(key & 0xFF)])
        case 46:    // INKEY
            regs[R.r3] = waitKey()
        case 48:
            storage.openFile(ioString(regs[R.r3]), handle: Int(bbSigned(regs[R.r1])))
        case 49:
            storage.closeFile(Int(bbSigned(argu)))
        case 50:
            let handle = Int(bbSigned(regs[R.r1]))
            let offset = Int(bbSigned(regs[R.r2]))
            switch argu {
            case 16:
                regs[R.r3] = storage.readInt(handle, offset: offset)
            case 17:
                regs[R.r3] = storage.readFloat(handle, offset: offset).bitPattern
            case 18:
                putString(regs[R.r3], storage.readString(handle, offset: offset))
            default:
                break
            }
        case 51:
            let handle = Int(bbSigned(regs[R.r1]))
            let offset = Int(bbSigned(regs[R.r2]))
            switch argu {
            case 16, 17:
                storage.writeInt(handle, offset: offset, value: regs[R.r3])
            case 18:
                storage.writeString(handle, offset: offset, bytes: ioString(regs[R.r3]))
            default:
                break
            }
        case 52:
            regs[R.r3] = storage.eof(Int(bbSigned(regs[R.r3]))) ? 1 : 0
        case 53:
            regs[R.r3] = storage.size(Int(bbSigned(regs[R.r3])))
        case 54:
            regs[R.r3] = storage.position(Int(bbSigned(regs[R.r3])))
        case 55:
            storage.movePosition(Int(bbSigned(regs[R.r2])), to: Int(bbSigned(regs[R.r3])))
        case 64:
            graphics.setPenColor(signedMem(regs[R.r3] + 12), color: getMem(regs[R.r3]))
        case 65:
            break
        case 66:
            graphics.movePen(Int(bbSigned(regs[R.r1])),
                             x: Int(bbSigned(regs[R.r2])),
                             y: Int(bbSigned(regs[R.r3])))
        case 67:
            graphics.drawLine(Int(bbSigned(regs[R.r1])),
                              x: Int(bbSigned(regs[R.r2])),
                              y: Int(bbSigned(regs[R.r3])))
        case 68:
            graphics.drawRectangle(signedMem(regs[R.r3] + 16),
                                   x1: signedMem(regs[R.r3] + 12),
                                   y1: signedMem(regs[R.r3] + 8),
                                   x2: signedMem(regs[R.r3] + 4),
                                   y2: signedMem(regs[R.r3]))
        case 69:
            graphics.drawCircle(signedMem(regs[R.r3] + 12),
                                x: signedMem(regs[R.r3] + 8),
                                y: signedMem(regs[R.r3] + 4),
                                r: signedMem(regs[R.r3]))
        case 80:
            graphics.cloneSurfaceRegion(x: signedMem(regs[R.r3] + 28),
                                        y: signedMem(regs[R.r3] + 24),
                                        width: signedMem(regs[R.r3] + 20),
                                        height: signedMem(regs[R.r3] + 16),
                                        cx: signedMem(regs[R.r3] + 12),
                                        cy: signedMem(regs[R.r3] + 8),
                                        dst: signedMem(regs[R.r3] + 4),
                                        src: signedMem(regs[R.r3]))
        default:
            break
        }
    }

    // MARK: - 辅助

    @inline(__always) private func signedMem(_ address: UInt32) -> Int {
        Int(bbSigned(getMem(address)))
    }

    private func waitKey() -> UInt32 {
        // 分片等：每 30ms 回来一次，顺手把金手指挂起的注入调用跑掉。
        // 死等的话游戏一旦停在「等玩家按键」，注入请求就永远排不上队。
        while true {
            if let key = input.waitKey(timeout: 0.03) { return key }
            if input.isStopped { return 0 }
            drainInjection()
        }
    }

    private func delay(milliseconds: Int) {
        var remaining = max(0, min(milliseconds, 30_000))
        let start = BBVM.clockSeconds()
        while remaining > 0 && !input.isStopped {
            let slice = min(remaining, 20)
            Thread.sleep(forTimeInterval: Double(slice) / 1000.0)
            remaining -= slice
        }
        // 记进「非执行时间」：主循环会把它加到时间轴上。
        // 不记的话，`delay(200)` 之后会立刻猛跑 200ms 的指令把账补上 ——
        // 程序里「慢慢走一步、等两秒」的节奏就变成了「慢慢走一步、立刻再走十步」。
        idleSeconds += BBVM.clockSeconds() - start
    }

    /// INPUT：逐字回显，Enter 结束，Backspace 擦除
    private func readLineInput() -> [UInt8] {
        var line: [UInt8] = []
        while true {
            guard let ch = input.waitTextChar() else { return line }
            if ch == 13 {
                break
            } else if ch == 8 || ch == 127 {
                if !line.isEmpty {
                    line.removeLast()
                    let x = max(0, screen.outputX - screen.fontWidth)
                    let y = screen.outputY
                    screen.setDispPosition(x: x, y: y)
                    screen.display([32])
                    screen.setDispPosition(x: x, y: y)
                }
            } else if ch == 27 {
                line.removeAll()
                screen.newLine()
            } else if ch >= 32, ch < 256 {
                line.append(UInt8(ch))
                screen.display([UInt8(ch)])
            }
        }
        screen.newLine()
        return line
    }
}
