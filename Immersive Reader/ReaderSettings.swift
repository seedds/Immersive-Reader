//
//  ReaderSettings.swift
//  Immersive Reader
//
//  Created by OpenCode on 26/4/2026.
//

import ReadiumNavigator
import Foundation

enum ReaderSettings {
    static let fontSizeKey = "readerFontSize"
    static let fontFamilyKey = "readerFontFamily"
    static let defaultFontSize = 1.0
    static let fontSizeRange = 0.8 ... 2.0
    static let fontSizeStep = 0.1

    static let fontFamilyOptions: [FontFamilyOption] = [
        FontFamilyOption(name: "Default", value: nil),
        FontFamilyOption(name: "Serif", value: .serif),
        FontFamilyOption(name: "Sans Serif", value: .sansSerif),
        FontFamilyOption(name: "OpenDyslexic", value: .openDyslexic),
        FontFamilyOption(name: "Iowan Old Style", value: .iowanOldStyle),
        FontFamilyOption(name: "Palatino", value: .palatino),
        FontFamilyOption(name: "Georgia", value: .georgia),
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

    static func normalizedFontSize(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

struct FontFamilyOption: Identifiable, Hashable {
    let name: String
    let value: FontFamily?

    var id: String {
        value?.rawValue ?? ""
    }
}
