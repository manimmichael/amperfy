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
    let layoutHeight = tableHeaderView?.frame.height ?? 0
    let canonicalHeight = GenericDetailTableHeader.frameHeight(
      traitCollection: viewController.traitCollection
    )
    let heroHeight = max(layoutHeight, canonicalHeight)

    guard heroHeight >= minimumHeroHeight else {
      stickyHeader.alpha = 0
      collapsedPlayItem?.isHidden = true
      return
    }

    let safeAreaTop = viewController.view.safeAreaInsets.top
    let navBarHeight = viewController.navigationController?.navigationBar.frame.height ?? 0
    let threshold = heroHeight - safeAreaTop - navBarHeight - stickyHeaderHeight
    let progress = max(0, min(1, (scrollView.contentOffset.y - threshold) / 20))
    stickyHeader.alpha = progress
    // Reveal the bar-level play action once the hero's own play CTA has
    // scrolled out from under the bar (midpoint of the title fade).
    collapsedPlayItem?.isHidden = progress < 0.5
  }
}
