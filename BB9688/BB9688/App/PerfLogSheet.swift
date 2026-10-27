//
//  PerfLogSheet.swift
//  BB9688
//
//  日志面板：开关记录、看文件、直接分享出去。
//
//  为什么要有它：
//    日志落在 Documents/PerfLog 里，「文件」App 能直接看，但一般人不会想到
//    去那儿翻；而「跑完把 CSV 发给我」这个动作，必须点两下就能完成，
//    否则又变成「算了不发了」。所以面板里每一行都带一个系统分享按钮。
//
//  只读文件、不改文件；删除只有「删除全部」一个入口，且要二次确认。
//

import SwiftUI

struct PerfLogSheet: View {

    @ObservedObject private var log = PerfLog.shared
    /// 和 RootView 的 @AppStorage 同一个键，改这里等于改全局开关
    @Binding var enabled: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var files: [PerfLog.FileInfo] = []
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    listSection
                    actionRow
                    pathNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.09, green: 0.10, blue: 0.12).ignoresSafeArea())
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onChange(of: enabled) { _ in reload() }
        .alert("删除全部日志？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                PerfLog.deleteAll()
                enabled = false
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这一条不可撤销。已经在别处留过副本就没事。")
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(enabled ? Color(red: 0.98, green: 0.35, blue: 0.33) : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text(enabled ? "正在记录" : "记录已关闭")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .tint(Color(red: 0.98, green: 0.35, blue: 0.33))

            if enabled {
                Text(log.currentName.isEmpty ? "正在建文件…" : "\(log.currentName)　·　\(log.lineCount) 行")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            } else {
                Text("打开后每秒写一行，收起屏幕上的监控条也照记。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: 文件列表

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日志文件（\(files.count)）")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .padding(.leading, 2)

            if files.isEmpty {
                Text("还没有日志。打开上面的开关跑一段就有了。")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { f in
                        fileRow(f)
                        if f.id != files.last?.id {
                            Divider().overlay(Color.white.opacity(0.07))
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
            }
        }
    }

    private func fileRow(_ f: PerfLog.FileInfo) -> some View {
        let current = f.name == log.currentName
        return HStack(spacing: 10) {
            Image(systemName: current ? "record.circle" : "doc.text")
                .font(.system(size: 13))
                .foregroundColor(current ? Color(red: 0.98, green: 0.35, blue: 0.33) : .white.opacity(0.35))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(f.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(byteText(f.bytes))　·　\(timeText(f.modified))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.42))
            }

            Spacer(minLength: 4)

            // 走系统分享面板：微信 / 邮件 / 存到「文件」都行，不需要电脑
            ShareLink(item: f.url) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("分享")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 操作

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                enabled = true
                PerfLog.shared.startNew()
                reload()
            } label: {
                Label("开始新的一份", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button {
                confirmDelete = true
            } label: {
                Label("删除全部", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.98, green: 0.45, blue: 0.42))
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.red.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(files.isEmpty)
        }
    }

    // MARK: 路径说明

    private var pathNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("文件就在「文件」App 里：我的 iPhone → 9688 → \(PerfLog.folderName)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            Text("只留最近 \(PerfLog.keepFiles) 份，单份超 8MB 自动换新。")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: 工具

    private func reload() {
        files = PerfLog.files()
    }

    private func byteText(_ n: Int) -> String {
        if n >= 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1048576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm 开始" : "MM-dd HH:mm"
        return f.string(from: d)
    }
}
