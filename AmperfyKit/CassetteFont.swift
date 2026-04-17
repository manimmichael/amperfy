//
//  CassetteFont.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  Typography tokens for Cassette. Display face is Barlow Condensed,
//  monospace face is DM Mono. Both are Google Fonts (OFL). The TTFs are
//  expected to live in Amperfy/Resources/Fonts/ and be listed under the
//  `UIAppFonts` key in Info.plist. If a custom font fails to load at
//  runtime (e.g. missing from the bundle), every API here falls back to
//  the system font so the app never crashes.
//
//  Weights wired up:
//    Barlow Condensed — Regular (400), SemiBold (600), Bold (700), ExtraBold (800)
//    DM Mono          — Regular (400), Medium (500)
//
//  Run `apps/cassette-player-ios/scripts/fetch-fonts.sh` from the wrapper
//  to download the TTFs from Google Fonts into Amperfy/Resources/Fonts/.
//

import SwiftUI
import UIKit

public enum CassetteDisplayWeight {
  case regular
  case semibold
  case bold
  case extraBold

  fileprivate var postScriptName: String {
    switch self {
    case .regular: return "BarlowCondensed-Regular"
    case .semibold: return "BarlowCondensed-SemiBold"
    case .bold: return "BarlowCondensed-Bold"
    case .extraBold: return "BarlowCondensed-ExtraBold"
    }
  }

  fileprivate var systemWeight: UIFont.Weight {
    switch self {
    case .regular: return .regular
    case .semibold: return .semibold
    case .bold: return .bold
    case .extraBold: return .heavy
    }
  }

  fileprivate var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: return .regular
    case .semibold: return .semibold
    case .bold: return .bold
    case .extraBold: return .heavy
    }
  }
}

public enum CassetteMonoWeight {
  case regular
  case medium

  fileprivate var postScriptName: String {
    switch self {
    case .regular: return "DMMono-Regular"
    case .medium: return "DMMono-Medium"
    }
  }

  fileprivate var systemWeight: UIFont.Weight {
    switch self {
    case .regular: return .regular
    case .medium: return .medium
    }
  }

  fileprivate var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: return .regular
    case .medium: return .medium
    }
  }
}

// MARK: - UIFont

extension UIFont {
  public static func cassetteDisplay(
    size: CGFloat,
    weight: CassetteDisplayWeight = .semibold
  ) -> UIFont {
    if let font = UIFont(name: weight.postScriptName, size: size) {
      return font
    }
    return UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  ) -> UIFont {
    if let font = UIFont(name: weight.postScriptName, size: size) {
      return font
    }
    return UIFont.monospacedSystemFont(ofSize: size, weight: weight.systemWeight)
  }
}

// MARK: - SwiftUI Font

extension Font {
  public static func cassetteDisplay(
    size: CGFloat,
    weight: CassetteDisplayWeight = .semibold
  ) -> Font {
    // SwiftUI's `Font(name:size:)` silently falls back to the system font
    // if the PostScript name can't be resolved, so we always ask for the
    // custom one and layer `.weight()` on top for the system fallback path.
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  ) -> Font {
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }
}
