//
//  DetailScreenChrome.swift
//  Amperfy
//
//  Cassette: the one detail-page frame (design-system audit 2026-10-20, Wave 3, DET-1).
//
//  Album, Artist and Playlist carried ~110 near-identical lines each of navigation-bar and
//  collapse choreography, and every fix to the header fade (rounds 3 to 7f, Patches 064 to
//  109) had to land in each copy; Playlist had already drifted (DET-2, DET-4). This object
//  owns all of it. A detail screen creates one, hands it the hero, and forwards five
//  lifecycle calls. The rules it enforces live here once:
//
//  - The bar is transparent in every appearance slot at rest, and its background fades in
//    with the title as the hero slides under it (Patch 109). Starting from the global opaque
//    appearance instead is what made a below-bar hero flash as the fade began.
//  - The title is the sticky header view only; `title` and `navigationItem.title` stay nil
//    (round 7c), and it is shown by `isHidden`, not just alpha (round 7f).
//  - The hero re-measures on every layout pass and when a scroll settles, never mid-scroll.
//  - Nothing recomputes while the screen is being popped (round 3).
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import UIKit

@MainActor
final class DetailScreenChrome {
  /// Where the hero sits relative to the navigation bar.
  enum HeroPlacement {
    /// The artwork runs up under a transparent bar (album, artist). The table's insets are
    /// mirrored by hand and the iOS 26 top scroll-edge scrim is hidden so the artwork is
    /// clean at rest.
    case underBar
    /// The hero starts below the bar with automatic insets (playlist, which has
    /// pull-to-refresh).
    case belowBar
  }

  let stickyHeader = DetailStickyHeaderView()
  let optionsItem: UIBarButtonItem
  let collapsedPlayItem: UIBarButtonItem
  private(set) var header: GenericDetailTableHeader?

  private weak var host: BasicTableViewController?
  private let placement: HeroPlacement

  /// - Parameters:
  ///   - menu: the overflow menu's actions, built on open.
  ///   - playContext: what the collapsed bar play button plays (the same context the hero's
  ///     own play button uses).
  init(
    host: BasicTableViewController,
    placement: HeroPlacement,
    menu: @escaping () -> [UIMenuElement],
    playContext: @escaping () -> PlayContext?
  ) {
    self.host = host
    self.placement = placement
    optionsItem = UIBarButtonItem.createOptionsBarButton()
    optionsItem.menu = UIMenu.lazyMenu(builder: menu)
    collapsedPlayItem = UIBarButtonItem(
      image: CassetteIcon.play.symbolImage,
      primaryAction: UIAction { _ in
        MainActor.assumeIsolated {
          guard let context = playContext() else { return }
          (UIApplication.shared.delegate as? AppDelegate)?.player.play(context: context)
        }
      }
    )
    collapsedPlayItem.accessibilityLabel = "Play"
    collapsedPlayItem.isHidden = true
  }

  /// Whether the hero header should extend under the bar (`DetailHeaderConfiguration`).
  var extendsUnderNavigationBar: Bool { placement == .underBar }

  // MARK: viewDidLoad

  /// Before `super.viewDidLoad()`: pin the inline title so the parent's large title does not
  /// flash through the push (Patch 037).
  func prepareBeforeLoad() {
    host?.navigationItem.largeTitleDisplayMode = .never
  }

  /// After the hero is built: bar appearance, insets, the sticky title and the trailing items.
  func install(header: GenericDetailTableHeader?, title: String?) {
    guard let host else { return }
    self.header = header
    let tableView = host.tableView!
    if placement == .underBar {
      tableView.contentInsetAdjustmentBehavior = .never
      if #available(iOS 26.0, *) {
        tableView.topEdgeEffect.isHidden = true
      }
    }
    let transparentBar = UINavigationBarAppearance()
    transparentBar.configureWithTransparentBackground()
    let item = host.navigationItem
    item.standardAppearance = transparentBar
    item.compactAppearance = transparentBar
    item.scrollEdgeAppearance = transparentBar
    item.compactScrollEdgeAppearance = transparentBar

    DetailStickyHeaderSupport.install(
      stickyHeader: stickyHeader,
      in: host,
      overflowItem: optionsItem,
      collapsedPlayItem: collapsedPlayItem
    )
    setTitle(title)
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }
  }

  /// The collapsed title. Call again whenever the entity's name can have changed.
  func setTitle(_ title: String?) {
    stickyHeader.configure(title: title ?? "", subtitle: nil)
  }

  /// Extra trailing bar items (Playlist's Edit) after the overflow and the collapsed play.
  func setExtraTrailingItems(_ items: [UIBarButtonItem]) {
    host?.navigationItem.rightBarButtonItems = [optionsItem, collapsedPlayItem] + items
  }

  // MARK: Lifecycle forwarding

  func viewIsAppearing() {
    // Restores the right alpha when popping back to a scrolled screen.
    updateCollapse()
  }

  func viewDidLayoutSubviews() {
    guard let host, !host.isHeaderTransitionFrozen else { return }
    if placement == .underBar {
      // With contentInsetAdjustmentBehavior == .never the safe areas are mirrored by hand
      // (bottom = tab bar + mini player); top stays 0 so the artwork reaches the top edge.
      host.tableView.contentInset.bottom = host.view.safeAreaInsets.bottom
      host.tableView.verticalScrollIndicatorInsets.top = host.view.safeAreaInsets.top
      host.tableView.verticalScrollIndicatorInsets.bottom = host.view.safeAreaInsets.bottom
    }
    // Width-keyed inside: a rotation or iPad resize re-measures; a no-op otherwise (DET-4).
    header?.resizeToFit()
  }

  func viewWillDisappear(isMovingFromParent: Bool) {
    guard let host else { return }
    if !isMovingFromParent {
      // Pushing a child: start its bar clean.
      stickyHeader.alpha = 0
    } else {
      // Popping (including the interactive edge swipe): hold everything as it is so the
      // hero rides off-screen instead of re-expanding. A cancelled swipe resumes.
      host.freezeCollapsingHeaderForPopTransition { [weak self] in
        self?.header?.resizeToFit()
        self?.updateCollapse()
      }
    }
  }

  func scrollViewDidScroll() {
    updateCollapse()
  }

  /// A scroll came to rest: land any re-measure `resizeToFit` deferred mid-scroll.
  func scrollDidSettle() {
    header?.resizeToFit()
  }

  private func updateCollapse() {
    guard let host else { return }
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: host.tableView,
      tableHeaderView: host.tableView.tableHeaderView,
      in: host,
      collapsedPlayItem: collapsedPlayItem
    )
  }
}
