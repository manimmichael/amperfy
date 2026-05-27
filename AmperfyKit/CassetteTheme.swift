//
//  CassetteTheme.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  Centralised design system for the Cassette reskin. Colors mirror the
//  tokens in `apps/cassette-player-ios/theme/cassette-tokens.md` and the
//  shared web/native palette. Every UI surface that needs a Cassette
//  background, text colour, separator, or accent should pull from here
//  rather than hardcoding hex values.
//
//  Backgrounds are layered (bg < bg2 < bg3, with bg4 as the deepest
//  surface used behind the now-playing artwork). Ink runs from primary
//  text down to the separator/border tint. Orange is the only accent
//  used for primary action; rust is its pressed/active variant.
//
//  `applyGlobalAppearance()` should be called once during app launch.
//  It sets `UIAppearance` proxies for the navigation bar, tab bar, table
//  views, segmented controls, and switches so every UIKit screen inherits
//  the Cassette palette without per-view boilerplate.
//

import SwiftUI
import UIKit

// MARK: - CassetteTheme

public enum CassetteTheme {
  // MARK: Spacing

  public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
  }

  // MARK: Radius

  public enum Radius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 12
    public static let pill: CGFloat = 100
  }

  // MARK: UIKit colours

  public enum UIColors {
    public static let bg = UIColor.cassetteHex(0x1C1914)
    public static let bg2 = UIColor.cassetteHex(0x221F19)
    public static let bg3 = UIColor.cassetteHex(0x2A261E)
    public static let bg4 = UIColor.cassetteHex(0x161310)

    public static let ink = UIColor.cassetteHex(0xEDE4D0)
    public static let ink2 = UIColor.cassetteHex(0xA89878)
    public static let ink3 = UIColor.cassetteHex(0x6E6050)
    public static let ink4 = UIColor.cassetteHex(0x3E3628)

    public static let orange = UIColor.cassetteHex(0xE87830)
    public static let rust = UIColor.cassetteHex(0xB84830)
    public static let sage = UIColor.cassetteHex(0x48987A)
    public static let amber = UIColor.cassetteHex(0xD4A020)
  }

  // MARK: SwiftUI colours

  public enum Colors {
    public static let bg = Color(UIColors.bg)
    public static let bg2 = Color(UIColors.bg2)
    public static let bg3 = Color(UIColors.bg3)
    public static let bg4 = Color(UIColors.bg4)

    public static let ink = Color(UIColors.ink)
    public static let ink2 = Color(UIColors.ink2)
    public static let ink3 = Color(UIColors.ink3)
    public static let ink4 = Color(UIColors.ink4)

    public static let orange = Color(UIColors.orange)
    public static let rust = Color(UIColors.rust)
    public static let sage = Color(UIColors.sage)
    public static let amber = Color(UIColors.amber)
  }

  // MARK: Global UIAppearance

  /// One-time configuration of UIAppearance proxies. Call from
  /// `application(_:didFinishLaunchingWithOptions:)` before any view
  /// hierarchy is constructed.
  public static func applyGlobalAppearance() {
    let nav = UINavigationBarAppearance()
    nav.configureWithOpaqueBackground()
    nav.backgroundColor = UIColors.bg
    nav.shadowColor = UIColors.ink4
    nav.titleTextAttributes = [
      .font: UIFont.cassetteDisplay(size: 18, weight: .semibold),
      .foregroundColor: UIColors.ink,
    ]
    nav.largeTitleTextAttributes = [
      .font: UIFont.cassetteDisplay(size: 34, weight: .bold),
      .foregroundColor: UIColors.ink,
    ]
    // cassette Patch 046 (Phase A): back button title drops to ink2 (was orange).
    // The chevron itself follows the global nav tintColor, also moved to ink.
    let backItem = UIBarButtonItemAppearance()
    backItem.normal.titleTextAttributes = [
      .foregroundColor: UIColors.ink2,
      .font: UIFont.cassette(.rowTitle),
    ]
    nav.buttonAppearance = backItem
    nav.backButtonAppearance = backItem

    UINavigationBar.appearance().standardAppearance = nav
    UINavigationBar.appearance().scrollEdgeAppearance = nav
    UINavigationBar.appearance().compactAppearance = nav
    UINavigationBar.appearance().tintColor = UIColors.ink

    // cassette Patch 046 (Phase A): tab bar selected icon + label drop to ink
    // (was orange). Differentiation between selected/unselected is now ink
    // (selected) vs ink3 (unselected) plus the existing bold/semibold label
    // weight contrast at lines below. Phase H will layer filled-vs-outline
    // icon swapping on top for the final structural cue.
    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = UIColors.bg2
    tab.shadowColor = UIColors.ink4
    let tabItem = UITabBarItemAppearance()
    tabItem.normal.iconColor = UIColors.ink3
    tabItem.normal.titleTextAttributes = [
      .foregroundColor: UIColors.ink3,
      .font: UIFont.cassetteDisplay(size: 10, weight: .semibold),
    ]
    tabItem.selected.iconColor = UIColors.ink
    tabItem.selected.titleTextAttributes = [
      .foregroundColor: UIColors.ink,
      .font: UIFont.cassetteDisplay(size: 10, weight: .bold),
    ]
    tab.stackedLayoutAppearance = tabItem
    tab.inlineLayoutAppearance = tabItem
    tab.compactInlineLayoutAppearance = tabItem
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab
    UITabBar.appearance().tintColor = UIColors.ink
    UITabBar.appearance().unselectedItemTintColor = UIColors.ink3

    UITableView.appearance().backgroundColor = UIColors.bg
    UITableView.appearance().separatorColor = UIColors.ink4
    UITableView.appearance().sectionIndexColor = UIColors.ink2

    UICollectionView.appearance().backgroundColor = UIColors.bg

    UISwitch.appearance().onTintColor = UIColors.orange

    let segmentNormal: [NSAttributedString.Key: Any] = [
      .foregroundColor: UIColors.ink2,
      .font: UIFont.cassette(.metadata),
    ]
    let segmentSelected: [NSAttributedString.Key: Any] = [
      .foregroundColor: UIColors.bg,
      .font: UIFont.cassette(.metadata),
    ]
    UISegmentedControl.appearance().setTitleTextAttributes(segmentNormal, for: .normal)
    UISegmentedControl.appearance().setTitleTextAttributes(segmentSelected, for: .selected)
    UISegmentedControl.appearance().selectedSegmentTintColor = UIColors.orange
    UISegmentedControl.appearance().backgroundColor = UIColors.bg2

    // cassette Patch 046 (Phase A): toolbar + search bar tint drop to ink/ink2.
    // The orange cursor + ring on search bars was loud and competed with the
    // mini-player scrubber visible at the bottom of the same screen.
    UIToolbar.appearance().barTintColor = UIColors.bg2
    UIToolbar.appearance().tintColor = UIColors.ink

    UISearchBar.appearance().tintColor = UIColors.ink2
    UISearchBar.appearance().barTintColor = UIColors.bg2
  }
}

// MARK: - UIColor hex helper

extension UIColor {
  /// Convenience initializer for the Cassette palette. Hex literal in
  /// the form `0xRRGGBB`. Always opaque.
  public static func cassetteHex(_ value: UInt32) -> UIColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }
}
