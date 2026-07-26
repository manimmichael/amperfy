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

// MARK: - CassetteDisplayWeight

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

// MARK: - CassetteMonoWeight

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
  )
    -> UIFont {
    if let font = UIFont(name: weight.postScriptName, size: size) {
      return font
    }
    return UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  )
    -> UIFont {
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
  )
    -> Font {
    // SwiftUI's `Font(name:size:)` silently falls back to the system font
    // if the PostScript name can't be resolved, so we always ask for the
    // custom one and layer `.weight()` on top for the system fallback path.
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  )
    -> Font {
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }
}

// MARK: - CassetteTextStyle

/// Canonical typography scale for the Cassette iOS fork. Roles map onto
/// Display (Barlow Condensed) / Mono (DM Mono), plus system `.body` where
/// SF Pro Text reads better than a condensed face.
///
/// Album/track titles stay on Barlow. The quieter line under a card (artist
/// name, resume artist) uses `.cardSubtitle`: DM Mono at the 13pt floor, which
/// stays more legible at that size than condensed Barlow.
///
/// Caption and `.metadata` share a size and are differentiated by weight
/// only (medium vs regular mono). The 12pt floor is a Cassette product
/// decision; iOS HIG would allow 11pt here but we don't.
///
/// cassette Patch 104 (Root 4): the scale read small on track numbers,
/// library rows and the Home greeting, so the roles were lifted app-wide
/// (roles, not per-screen sizes): heroTitle 28 -> 30, rowTitle 16 -> 18,
/// miniTitle 14 -> 15, metadata/caption 12 -> 13. sectionTitle stays 22.
/// `.greeting` is new: the Home greeting used to fall back to tiny 12pt
/// mono (the prototype's Newsreader face isn't bundled) - it now gets a
/// real Barlow treatment at a legible size.
public enum CassetteTextStyle {
  case heroTitle // Barlow Condensed Bold, 30pt
  case sectionTitle // Barlow Condensed Bold, 22pt
  case greeting // Barlow Condensed SemiBold, 20pt (Home greeting line)
  case rowTitle // Barlow Condensed Semibold, 18pt
  case miniTitle // Barlow Condensed Semibold, 15pt
  case sectionLabel // Barlow Condensed Bold, 13pt (callers uppercase as needed)
  case cardSubtitle // DM Mono Regular, 13pt (artist under an album/resume card)
  case metadata // DM Mono Medium, 13pt
  case caption // DM Mono Regular, 13pt
  case body // SF Pro Text Regular, 15pt (system font, not Cassette Display)
}

extension UIFont {
  public static func cassette(_ style: CassetteTextStyle) -> UIFont {
    switch style {
    case .heroTitle:
      return .cassetteDisplay(size: 30, weight: .bold)
    case .sectionTitle:
      return .cassetteDisplay(size: 22, weight: .bold)
    case .greeting:
      return .cassetteDisplay(size: 20, weight: .semibold)
    case .rowTitle:
      return .cassetteDisplay(size: 18, weight: .semibold)
    case .miniTitle:
      return .cassetteDisplay(size: 15, weight: .semibold)
    case .sectionLabel:
      return .cassetteDisplay(size: 13, weight: .bold)
    case .cardSubtitle:
      return .cassetteMono(size: 13, weight: .regular)
    case .metadata:
      return .cassetteMono(size: 13, weight: .medium)
    case .caption:
      return .cassetteMono(size: 13, weight: .regular)
    case .body:
      return .systemFont(ofSize: 15, weight: .regular)
    }
  }
}

extension Font {
  public static func cassette(_ style: CassetteTextStyle) -> Font {
    switch style {
    case .heroTitle:
      return .cassetteDisplay(size: 30, weight: .bold)
    case .sectionTitle:
      return .cassetteDisplay(size: 22, weight: .bold)
    case .greeting:
      return .cassetteDisplay(size: 20, weight: .semibold)
    case .rowTitle:
      return .cassetteDisplay(size: 18, weight: .semibold)
    case .miniTitle:
      return .cassetteDisplay(size: 15, weight: .semibold)
    case .sectionLabel:
      return .cassetteDisplay(size: 13, weight: .bold)
    case .cardSubtitle:
      return .cassetteMono(size: 13, weight: .regular)
    case .metadata:
      return .cassetteMono(size: 13, weight: .medium)
    case .caption:
      return .cassetteMono(size: 13, weight: .regular)
    case .body:
      return .system(size: 15, weight: .regular)
    }
  }
}
