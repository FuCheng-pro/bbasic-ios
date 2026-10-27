//
//  SettingsScreen.swift
//  BB9688
//
//  设置页：240×320 矢量界面，和「本机信息」同一套纸张风。
//
//  入口是程序列表最后一行「设置」（摇杆推到底 + 中键）。
//  操作全在物理键上 —— 9688 不是触屏，设置页也不该是：
//    摇杆 ↑↓   换行（首尾相接）
//    中键 / 右键  切换开关、循环速度、进日志面板
//    左键      返回列表
//
//  为什么速度用「循环」而不是左右调值：
//    摇杆斜推时判向偶尔会落到左右，若左右也改值，速度会莫名其妙跳档。
//    上下选行是明确的，中键循环也是明确的，两者不会互相干扰。
//

import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var settings = BBSettings.shared

    // 纸张风配色，与 AboutScreen 一致
    private let ink = Color(red: 0.13, green: 0.20, blue: 0.30)
    private let faint = Color(red: 0.48, green: 0.55, blue: 0.63)
    private let rule = Color(red: 0.81, green: 0.85, blue: 0.90)
    private let paper = Color(red: 0.984, green: 0.988, blue: 0.996)
    private let selFill = Color(red: 0.10, green: 0.25, blue: 0.44)
    private let onGreen = Color(red: 0.09, green: 0.50, blue: 0.30)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(red: 0.07, green: 0.20, blue: 0.36))
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(rule).frame(height: 1)
                }

            VStack(spacing: 3) {
                ForEach(AppModel.SettingRow.allCases, id: \.self) { row in
                    rowView(row, selected: row.rawValue == app.settingsIndex)
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 0)

            // 当前选中项的说明：屏幕窄，把解释放在这里比塞进每行更清楚
            Text(currentDetail)
                .font(.system(size: 8))
                .foregroundColor(faint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("摇杆 选择　中键 切换　左键 返回")
                .font(.system(size: 8.5))
                .foregroundColor(Color(red: 0.53, green: 0.58, blue: 0.66))
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .center)
                .overlay(alignment: .top) {
                    Rectangle().fill(rule).frame(height: 1)
                }
        }
        .padding(10)
        .frame(width: 240, height: 320, alignment: .topLeading)
        .background(paper)
    }

    // MARK: - 行

    private func rowView(_ row: AppModel.SettingRow, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(row.title)
                .font(.system(size: 11, weight: selected ? .bold : .regular))
                .foregroundColor(selected ? Color.white : ink)

            Spacer(minLength: 4)

            Text(valueText(row))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(selected ? Color.white.opacity(0.92) : valueColor(row))
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? selFill : Color.clear)
        )
    }

    private func valueText(_ row: AppModel.SettingRow) -> String {
        switch row {
        case .perf:    return settings.showPerf ? "开" : "关"
        case .log:     return settings.logEnabled ? "开" : "关"
        case .bgm:     return settings.bgm ? "开" : "关"
        case .speed:   return "\(settings.speedLabel)"
        case .logFile: return "›"
        case .power:   return "›"
        }
    }

    private func valueColor(_ row: AppModel.SettingRow) -> Color {
        switch row {
        case .perf:    return settings.showPerf ? onGreen : faint
        case .log:     return settings.logEnabled ? onGreen : faint
        case .bgm:     return settings.bgm ? onGreen : faint
        case .speed:   return Color(red: 0.15, green: 0.32, blue: 0.56)
        default:       return faint
        }
    }

    private var currentDetail: String {
        guard let row = AppModel.SettingRow(rawValue: app.settingsIndex) else { return "" }
        if row == .speed {
            return "\(row.detail)：\(settings.speedLabel) ≈ \(settings.wanSteps) 万条/秒（原机手感约 200 万）"
        }
        return row.detail
    }
}
