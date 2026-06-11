//
//  DetailStickyHeaderSupport.swift
//  Amperfy
//
//  cassette Patch 064: shared scroll threshold for detail sticky headers.
//  cassette Patch 066: guard zero-height header + revised threshold math.
//  cassette redesign (Surface 1): the collapsed state lives entirely in the
//  NATIVE navigation bar — iOS 26 supplies the Liquid Glass treatment for
//  the bar and its buttons. At rest the bar shows back + overflow; as the
//  hero scrolls under, the title fades in and a trailing play bar-button
//  appears alongside the overflow.

import AmperfyKit
import UIKit

@MainActor
enum DetailStickyHeaderSupport {
  private static let stickyHeaderHeight: CGFloat = 56
  private static let minimumHeroHeight: CGFloat = 50

  /// Mounts the fade-in title as the navigation bar's titleView and installs
  /// the trailing bar items. `overflowItem` is always visible; the optional
  /// `collapsedPlayItem` starts hidden and is revealed by `updateAlpha` when
  /// the hero collapses.
  static func install(
    stickyHeader: DetailStickyHeaderView,
    in viewController: UIViewController,
    overflowItem: UIBarButtonItem? = nil,
    collapsedPlayItem: UIBarButtonItem? = nil
  ) {
    viewController.navigationItem.titleView = stickyHeader
    stickyHeader.alpha = 0
    collapsedPlayItem?.isHidden = true
    let trailingItems = [overflowItem, collapsedPlayItem].compactMap { $0 }
    if !trailingItems.isEmpty {
      viewController.navigationItem.rightBarButtonItems = trailingItems
    }
  }

  static func updateAlpha(
    stickyHeader: DetailStickyHeaderView,
    scrollView: UIScrollView,
    tableHeaderView: UIView?,
    in viewController: UIViewController,
    collapsedPlayItem: UIBarButtonItem? = nil
  ) {
    // cassette Patch 104 (Root 2): the header self-sizes now, so the hero
    // height is read from the actual table header frame (no canonical
    // constants), and the threshold is computed by converting the hero's
    // bottom edge into the root view's coordinate space. That keeps the
    // math correct both for the album/artist headers that extend under the
    // bar (contentInsetAdjustmentBehavior == .never) and for the detail
    // screens that still lay out below it.
    guard let tableHeaderView,
          tableHeaderView.frame.height >= minimumHeroHeight else {
      stickyHeader.alpha = 0
      collapsedPlayItem?.isHidden = true
      return
    }

    let heroBottomY = scrollView.convert(
      CGPoint(x: 0, y: tableHeaderView.frame.maxY),
      to: viewController.view
    ).y
    let barBottomY = viewController.view.safeAreaInsets.top
    // Title fades in over the last 20pt of the hero sliding under the bar.
    let progress = max(0, min(1, (barBottomY + 20 - heroBottomY) / 20))
    stickyHeader.alpha = progress
    // Reveal the bar-level play action once the hero's own play CTA has
    // scrolled out from under the bar (midpoint of the title fade).
    collapsedPlayItem?.isHidden = progress < 0.5
  }
}
