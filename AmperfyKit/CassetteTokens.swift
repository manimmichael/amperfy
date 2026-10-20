//
//  CassetteTokens.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  The semantic tier of the design system (design-system audit 2026-10-20, Wave 2).
//
//  Screens ask for a ROLE ("secondary text", "raised surface"), never a palette step
//  ("ink2", "bg2"). The palette in `CassetteTheme.UIColors` / `.Colors` is what the roles
//  resolve to; it stays public only until every call site has moved, then it goes private
//  so the compiler is the gate. One table below feeds UIKit and SwiftUI alike, the same way
//  `CassetteTextStyle` feeds `UIFont.cassette` and `Font.cassette`.
//
//  Usage: `label.textColor = .cassette(.textSecondary)`,
//         `.foregroundStyle(Color.cassette(.textSecondary))`,
//         `layer.cornerRadius = CassetteRadius.card`.
//
//  CarPlay draws none of these: its template content follows the car (`CarPlayStyle`).
//

import SwiftUI
import UIKit

// MARK: - CassetteColorRole

public enum CassetteColorRole: CaseIterable, Sendable {
  // MARK: Surfaces (darkest first)

  /// Behind the now-playing artwork and the player sheets. Darker than `surfaceBase`.
  case surfaceSunken
  /// The page: every list, grid and screen background.
  case surfaceBase
  /// A card, a banner, the tab bar, a grouped settings row.
  case surfaceRaised
  /// Something on a raised surface: a placeholder tile, a chip, a pressed row.
  case surfaceElevated
  /// Borders, hairlines, the nav bar shadow, tracks of an unfilled slider.
  case hairline

  // MARK: Text and icons

  /// Titles and body text; primary icons and the global tint.
  case textPrimary
  /// Subtitles, metadata, secondary icons, back-button titles.
  case textSecondary
  /// The quietest readable text: track numbers, footers, unselected tab labels.
  /// Note: at #6E6050 this is under 4.5:1 on the page (audit A11Y-3). Whether to lighten
  /// it or fold it into `textSecondary` (as the web did) is the founder's palette call.
  case textTertiary
  /// Text and icons sitting on `fillSelected` or on `accentProgress`.
  case textOnFill

  // MARK: Fills

  /// A selected or ON control: the selected segment, a switch that is on, a filled toggle.
  case fillSelected

  // MARK: Accent and state

  /// The one brand accent: playback progress (both scrubbers) and the now-playing waveform.
  /// Reserved; see `theme/cassette-tokens.md`.
  case accentProgress
  /// Destructive actions and errors (web `.cs-btn-danger`).
  case danger
  /// Something worked.
  case success
  /// Needs attention, not an error.
  case warning

  public var uiColor: UIColor {
    let p = CassetteTheme.UIColors.self
    switch self {
    case .surfaceSunken: return p.bg4
    case .surfaceBase: return p.bg
    case .surfaceRaised: return p.bg2
    case .surfaceElevated: return p.bg3
    case .hairline: return p.ink4
    case .textPrimary: return p.ink
    case .textSecondary: return p.ink2
    case .textTertiary: return p.ink3
    case .textOnFill: return p.bg
    case .fillSelected: return p.ink
    case .accentProgress: return p.orange
    case .danger: return p.rust
    case .success: return p.sage
    case .warning: return p.amber
    }
  }
}

extension UIColor {
  /// The color for a design-system role. See `CassetteColorRole`.
  public static func cassette(_ role: CassetteColorRole) -> UIColor {
    role.uiColor
  }
}

extension Color {
  /// The color for a design-system role. See `CassetteColorRole`.
  public static func cassette(_ role: CassetteColorRole) -> Color {
    Color(uiColor: role.uiColor)
  }
}

// MARK: - CassetteRadius

/// Every corner radius in the app, by what it rounds. The values are today's, unchanged:
/// consolidating them (for example artwork 3 and 5 into one) is a visual decision, made here
/// once when it is made. `CassetteTheme.Radius` and Amperfy's `CornerRadius` both resolve to
/// these.
public enum CassetteRadius {
  /// Album art in carousels, grids and the detail header.
  public static let artworkTile: CGFloat = 3
  /// Album art in list rows and the players.
  public static let artworkRow: CGFloat = 5
  /// Small controls and chips.
  public static let small: CGFloat = 4
  /// Buttons, fields, the radio dial tiles.
  public static let control: CGFloat = 8
  /// Grouped panels.
  public static let panel: CGFloat = 12
  /// Cards and banners (the sync banner, settings cards).
  public static let card: CGFloat = 14
  /// Amperfy's large rounding (popups).
  public static let large: CGFloat = 15
  /// Sheets presented over the app.
  public static let sheet: CGFloat = 28
  /// Fully round ends (capsules); use with a height under 200pt.
  public static let pill: CGFloat = 100
}

// MARK: - CassetteOpacity

/// The alpha steps the app uses, so "pressed" and "disabled" mean one thing everywhere.
public enum CassetteOpacity {
  /// A barely-there wash, such as a ghost initial or a pressed highlight on dark.
  public static let faint: CGFloat = 0.08
  /// A scrim over content behind a sheet or banner.
  public static let scrim: CGFloat = 0.5
  /// A control that cannot be used right now.
  public static let disabled: CGFloat = 0.4
}
