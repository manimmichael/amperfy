//
//  DetailStickyHeaderSupport.swift
//  Amperfy
//
//  cassette Patch 064: shared scroll threshold for detail sticky headers.
//  cassette Patch 066: guard zero-height header + revised threshold math.

import AmperfyKit
import UIKit

@MainActor
enum DetailStickyHeaderSupport {
  private static let stickyHeaderHeight: CGFloat = 56
  private static let minimumHeroHeight: CGFloat = 50

  static func install(
    stickyHeader: DetailStickyHeaderView,
    in viewController: UIViewController
  ) {
    // cassette Polish 2 (D3): mount the fade-in title in the navigation bar
    // itself instead of a separate band below the safe area. At rest alpha = 0
    // so the nav bar shows only the back button.
    viewController.navigationItem.titleView = stickyHeader
    stickyHeader.alpha = 0
  }

  static func updateAlpha(
    stickyHeader: DetailStickyHeaderView,
    scrollView: UIScrollView,
    tableHeaderView: UIView?,
    in viewController: UIViewController
  ) {
    let layoutHeight = tableHeaderView?.frame.height ?? 0
    let canonicalHeight = GenericDetailTableHeader.frameHeight(
      traitCollection: viewController.traitCollection
    )
    let heroHeight = max(layoutHeight, canonicalHeight)

    guard heroHeight >= minimumHeroHeight else {
      stickyHeader.alpha = 0
      return
    }

    let safeAreaTop = viewController.view.safeAreaInsets.top
    let navBarHeight = viewController.navigationController?.navigationBar.frame.height ?? 0
    let threshold = heroHeight - safeAreaTop - navBarHeight - stickyHeaderHeight
    let progress = max(0, min(1, (scrollView.contentOffset.y - threshold) / 20))
    stickyHeader.alpha = progress
  }
}
