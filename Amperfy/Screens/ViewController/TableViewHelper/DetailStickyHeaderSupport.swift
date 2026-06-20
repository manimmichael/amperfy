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
    // cassette (header-pop fix, round 3): while the host VC is popping out
    // (interactive edge-swipe back) hold the title/bar exactly as they are.
    // The scrollViewDidScroll / viewIsAppearing paths still fire mid-transition
    // (UIKit nudges contentOffset and the inset as the bar animates toward the
    // destination's large-title layout); recomputing here would re-fade the
    // title and, via the bar-appearance reassignment, force a re-render that
    // contributes to the hero re-expanding. Freeze; the completion handler (or a
    // cancelled-swipe restore) resumes normal updates.
    if (viewController as? BasicTableViewController)?.isHeaderTransitionFrozen == true {
      // round 4: HIDE the title for the duration of the pop rather than HOLDING
      // it. Round 3 froze the alpha at its pre-pop value, so a title that was
      // visible in the collapsed state stayed visible and overlapped the
      // (frozen) hero as the VC rode off. Forcing alpha 0 means the title
      // neither appears nor overlaps during the swipe; a cancelled swipe
      // restores the correct alpha via restoreOnCancel → updateAlpha (unfrozen).
      stickyHeader.alpha = 0
      collapsedPlayItem?.isHidden = true
      return
    }
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

    // Patch 108: the detail VCs are UITableViewController subclasses, so
    // `viewController.view === scrollView` and the old
    // `scrollView.convert(_, to: viewController.view)` was an identity
    // transform — heroBottomY never tracked the scroll and the title never
    // faded in. The hero is the table header (content origin y == 0) and the
    // table view fills the screen from the top, so the hero's bottom edge in
    // screen space is simply maxY minus the current content offset.
    let heroBottomY = tableHeaderView.frame.maxY - scrollView.contentOffset.y
    let barBottomY = viewController.view.safeAreaInsets.top
    // Patch 108: start later + gentler. The title stays absent until the hero
    // is essentially under the bar, then cross-fades in over `fadeDistance` pt
    // of scroll (was a ~20pt near-snap). progress is monotonic in
    // -heroBottomY, so once it reaches 1 it stays 1 for the rest of the scroll.
    let fadeDistance: CGFloat = 100
    let progress = max(0, min(1, (barBottomY + fadeDistance - heroBottomY) / fadeDistance))
    stickyHeader.alpha = progress
    // Patch 109: fade the bar background in lockstep with the title. Without
    // this UIKit snaps the opaque standardAppearance in the instant the user
    // scrolls (offset > 0), covering the still-visible artwork. The detail VCs
    // keep every appearance slot transparent at rest; here we paint a flat bg
    // whose alpha rides `progress`, so the bar surface and the title arrive
    // together only once the hero has slid under the bar. Reassigning a nav-bar
    // appearance forces a re-render, so skip it outside the fade window where
    // the alpha has already settled at 0 or 1.
    let item = viewController.navigationItem
    let currentBarAlpha = item.standardAppearance?.backgroundColor?.cgColor.alpha ?? 0
    if abs(currentBarAlpha - progress) > 0.01 {
      let barAppearance = UINavigationBarAppearance()
      barAppearance.configureWithTransparentBackground()
      barAppearance.backgroundColor = CassetteTheme.UIColors.bg.withAlphaComponent(progress)
      barAppearance.shadowColor = CassetteTheme.UIColors.ink4.withAlphaComponent(progress)
      item.standardAppearance = barAppearance
      item.scrollEdgeAppearance = barAppearance
      item.compactAppearance = barAppearance
      item.compactScrollEdgeAppearance = barAppearance
    }
    // Reveal the bar-level play action once the hero's own play CTA has
    // scrolled out from under the bar (midpoint of the title fade).
    collapsedPlayItem?.isHidden = progress < 0.5
  }
}
