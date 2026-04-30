//
//  ReaderSettings.swift
//  Immersive Reader
//
//  Created by OpenCode on 26/4/2026.
//

import Foundation
import ReadiumNavigator
import SwiftUI
import UIKit

nonisolated enum ReaderSettings {
    static let fontSizeKey = "readerFontSize"
    static let lineHeightKey = "readerLineHeight"
    static let fontFamilyKey = "readerFontFamily"
    static let themeKey = "readerTheme"
    static let readAloudColorKey = "readerReadAloudColor"
    static let playbackSpeedKey = "readerPlaybackSpeed"
    static let playbackJumpIntervalKey = "readerPlaybackJumpInterval"
    static let uploadServerPortKey = "uploadServerPort"
    static let defaultFontSize = 1.2
    static let defaultLineHeight = 1.2
    static let defaultReadAloudColorHex = "#34C759"
    static let defaultPlaybackSpeed = 1.0
    static let defaultPlaybackJumpInterval = 15.0
    static let defaultUploadServerPort = 80
    static let fontSizeRange = 0.8 ... 2.0
    static let lineHeightRange = 1.0 ... 2.0
    static let playbackSpeedRange = 0.5 ... 2.0
    static let fontSizeStep = 0.1
    static let lineHeightStep = 0.1
    static let playbackSpeedStep = 0.1
    static let playbackJumpIntervalOptions = [15.0, 30.0, 45.0, 60.0]

    static let fontFamilyOptions: [FontFamilyOption] = [
        FontFamilyOption(name: "Default", value: nil),
        FontFamilyOption(name: "Serif", value: .serif),
        FontFamilyOption(name: "Sans Serif", value: .sansSerif),
        FontFamilyOption(name: "OpenDyslexic", value: .openDyslexic),
        FontFamilyOption(name: "Iowan Old Style", value: .iowanOldStyle),
        FontFamilyOption(name: "Palatino", value: .palatino),
        FontFamilyOption(name: "Georgia", value: .georgia),
        FontFamilyOption(name: "Literata", value: "Literata"),
        FontFamilyOption(name: "Helvetica Neue", value: .helveticaNeue),
        FontFamilyOption(name: "Seravek", value: .seravek),
        FontFamilyOption(name: "Arial", value: .arial),
    ]

    static func fontFamily(from rawValue: String) -> FontFamily? {
        guard !rawValue.isEmpty else {
            return nil
        }
        return FontFamily(rawValue: rawValue)
    }

    static func appTheme(from rawValue: String) -> AppThemeOption {
        AppThemeOption(rawValue: rawValue) ?? .system
    }

    static func normalizedFontSize(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func normalizedLineHeight(_ value: Double) -> Double {
        min(max(value, lineHeightRange.lowerBound), lineHeightRange.upperBound)
    }

    static func normalizedPlaybackSpeed(_ value: Double) -> Double {
        min(max(value, playbackSpeedRange.lowerBound), playbackSpeedRange.upperBound)
    }

    static func normalizedPlaybackJumpInterval(_ value: Double) -> Double {
        playbackJumpIntervalOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultPlaybackJumpInterval
    }

    static func normalizedUploadServerPort(_ value: Int) -> Int {
        min(max(value, 1), Int(UInt16.max))
    }

    static func uploadServerPort(from value: Int) -> UInt16 {
        UInt16(normalizedUploadServerPort(value))
    }

    static func storedUploadServerPort() -> UInt16 {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: uploadServerPortKey) != nil else {
            return uploadServerPort(from: defaultUploadServerPort)
        }
        return uploadServerPort(from: defaults.integer(forKey: uploadServerPortKey))
    }

    static func playbackSpeedText(_ value: Double) -> String {
        let normalized = normalizedPlaybackSpeed(value)
        let roundedValue = normalized.rounded()
        let numberText = roundedValue == normalized
            ? roundedValue.formatted(.number.precision(.fractionLength(0)))
            : normalized.formatted(.number.precision(.fractionLength(1)))
        return "\(numberText)x"
    }

    static func playbackJumpIntervalText(_ value: Double) -> String {
        let normalized = normalizedPlaybackJumpInterval(value)
        let wholeSeconds = Int(normalized.rounded())
        return "\(wholeSeconds)s"
    }

    static func playbackJumpLabel(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let prefix = direction == .backward ? "-" : "+"
        return "\(prefix)\(playbackJumpIntervalText(value))"
    }

    static func playbackJumpSymbolName(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let wholeSeconds = Int(normalizedPlaybackJumpInterval(value).rounded())
        switch direction {
        case .backward:
            return "gobackward.\(wholeSeconds)"
        case .forward:
            return "goforward.\(wholeSeconds)"
        }
    }

    static func playbackJumpAccessibilityLabel(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let wholeSeconds = Int(normalizedPlaybackJumpInterval(value).rounded())
        switch direction {
        case .backward:
            return "Back \(wholeSeconds) seconds"
        case .forward:
            return "Forward \(wholeSeconds) seconds"
        }
    }

    static func fontSizeText(_ value: Double) -> String {
        normalizedFontSize(value)
            .formatted(.number.precision(.fractionLength(1)))
    }

    static func lineHeightText(_ value: Double) -> String {
        normalizedLineHeight(value)
            .formatted(.number.precision(.fractionLength(1)))
    }

    static func uiColor(from rawValue: String) -> UIColor {
        colorHex(from: rawValue)
            .flatMap(uiColor(hex:))
            ?? uiColor(hex: defaultReadAloudColorHex)
            ?? .systemGreen
    }

    static func color(from rawValue: String) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: uiColor(from: rawValue))
    }

    static func readAloudColorHex(from color: SwiftUI.Color) -> String {
        hexString(for: UIColor(color))
    }

    static func readAloudColorText(from rawValue: String) -> String {
        String(colorHex(from: rawValue)?.dropFirst() ?? defaultReadAloudColorHex.dropFirst())
    }

    static func normalizedReadAloudColorText(_ value: String) -> String {
        String(value.uppercased().filter(\.isHexDigit).prefix(6))
    }

    static func readAloudColorHex(from text: String) -> String? {
        let normalized = normalizedReadAloudColorText(text)
        guard normalized.count == 6 else {
            return nil
        }
        return "#\(normalized)"
    }

    static func readAloudColorHSB(from rawValue: String) -> ReadAloudColorHSB {
        let color = uiColor(from: rawValue)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .default
        }

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue

        let hue: CGFloat
        if delta == 0 {
            hue = 0
        } else if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }

        let normalizedHue = hue < 0 ? (hue + 6) / 6 : hue / 6
        let saturation = maxValue == 0 ? 0 : delta / maxValue

        return ReadAloudColorHSB(
            hue: clamp(Double(normalizedHue)),
            saturation: clamp(Double(saturation)),
            brightness: clamp(Double(maxValue))
        )
    }

    static func readAloudColorHex(hue: Double, saturation: Double, brightness: Double) -> String {
        hexString(
            for: UIColor(
                hue: clamp(hue),
                saturation: clamp(saturation),
                brightness: clamp(brightness),
                alpha: 1
            )
        )
    }

    private static func colorHex(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#") else {
            return nil
        }

        let hex = trimmed.dropFirst()
        guard hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        return trimmed.uppercased()
    }

    private static func uiColor(hex: String) -> UIColor? {
        guard let hex = colorHex(from: hex) else {
            return nil
        }

        let scanner = Scanner(string: String(hex.dropFirst()))
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber) else {
            return nil
        }

        return UIColor(
            red: CGFloat((hexNumber & 0xFF0000) >> 16) / 255,
            green: CGFloat((hexNumber & 0x00FF00) >> 8) / 255,
            blue: CGFloat(hexNumber & 0x0000FF) / 255,
            alpha: 1
        )
    }

    private static func hexString(for color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return defaultReadAloudColorHex
        }

        let rgb = (Int(round(red * 255)) << 16)
            | (Int(round(green * 255)) << 8)
            | Int(round(blue * 255))
        return String(format: "#%06X", rgb)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated struct ReadAloudColorHSB: Equatable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    static let `default` = ReadAloudColorHSB(hue: 0.4, saturation: 0.74, brightness: 0.78)
}

enum AppThemeOption: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func readiumTheme(for colorScheme: ColorScheme) -> Theme {
        switch self {
        case .system:
            return colorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct ReaderSettingSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 12)

                Text(valueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
        }
    }
}

struct FontFamilyOption: Identifiable, Hashable {
    let name: String
    let value: FontFamily?

    var id: String {
        value?.rawValue ?? ""
    }
}

nonisolated enum PlaybackJumpDirection {
    case backward
    case forward
}
