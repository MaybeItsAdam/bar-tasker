import AppKit
import SwiftUI

enum BarTaskerTypography {
  private static let lilexCandidates = [
    "Lilex",
    "LilexNerdFont",
    "Lilex Nerd Font",
    "LilexNerdFont-Regular",
  ]

  private static let resolvedLilexFontName: String? = {
    lilexCandidates.first(where: { NSFont(name: $0, size: 13) != nil })
  }()

  static var interfaceFont: Font {
    .system(.body, design: .default)
  }

  static func interfaceNSFont(ofSize size: CGFloat) -> NSFont {
    .systemFont(ofSize: size)
  }

  static func taskFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if let resolvedLilexFontName {
      return Font.custom(resolvedLilexFontName, size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .default)
  }

  static func taskNSFont(ofSize size: CGFloat) -> NSFont {
    if let resolvedLilexFontName, let font = NSFont(name: resolvedLilexFontName, size: size) {
      return font
    }
    return .systemFont(ofSize: size)
  }
}
