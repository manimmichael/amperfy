//
//  TabBarVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import UIKit.UIGestureRecognizerSubclass

// MARK: - TabBarVC

class TabBarVC: UITabBarController {
  private var libraryGroup: UITabGroup?
  private var searchTab: UISearchTab?
  private var homeTab: UITab?
  private let account: Account

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var welcomePopupPresenter = WelcomePopupPresenter()
  var miniPlayer: MiniPlayerView?

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UISearchTab { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.search
          .getController(account: self.account)
      )
    }
    searchTab!.automaticallyActivatesSearch = true
    fixTabs.append(searchTab!)

    // cassette Patch 053 (Phase H): tabs start with the outline icon. The
    // filled icon is swapped in for the currently-selected tab by the
    // `tabBarController(_:didSelectTab:previousTab:)` delegate callback
    // below, plus the initial `applySelectedTabIcon` after `selectedTab`
    // is set in `viewIsAppearing`. Selection cue is structural
    // (outline/filled) rather than chromatic.
    homeTab = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.outlineIcon,
      identifier: "Tabs.\(TabNavigatorItem.home.title)"
    ) { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
    }
    fixTabs.append(homeTab!)

    var libraryTabs = [UITab]()
    let libraryTabsShown = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.inUse
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.outlineImage,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsShown)

    let libraryTabsHidden = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.notUsed
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.outlineImage,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        tab.isHiddenByDefault = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsHidden)

    libraryGroup = UITabGroup(
      title: "Library",
      image: .musicLibraryOutline,
      identifier: "Tabs.Library",
      children: libraryTabs
    ) { tab in
      // cassette Patch 039: route the Library tab root to the new
      // dropdown container instead of the legacy intermediate
      // category list. LibraryVC stays reachable via direct
      // `segueToLibrary` callers (pushLibraryCategory, Mac sidebar).
      AppStoryboard.Main.segueToLibraryContainer(account: self.account)
    }
    libraryGroup!.managingNavigationController = UINavigationController()
    libraryGroup!.allowsReordering = true
    fixTabs.append(libraryGroup!)

    delegate = self
    tabs = fixTabs

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryItemsChanged(notification:)),
      name: .LibraryItemsChanged,
      object: nil
    )

    // cassette: `.onScrollDown` minimizes the tab bar as the user scrolls DOWN and
    // brings it back the moment they scroll UP (the Reddit feel). `.automatic`
    // resolved to no-minimize for our tab-bar-with-mini-player config, so we set
    // the explicit behavior. Options: `.onScrollDown` (this), `.never` (pinned),
    // `.automatic` (system default → no-shrink here), `.onScrollUp`.
    tabBarMinimizeBehavior = .onScrollDown

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    miniPlayer!.glassContainer.translatesAutoresizingMaskIntoConstraints = false

    let accessory = UITabAccessory(contentView: miniPlayer!.glassContainer)
    bottomAccessory = accessory
    view.addGestureRecognizer(RailTouchDownObserver { [weak self] point in
      self?.railTouchDown(at: point)
    })

    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    heightConstraint?.isActive = true
    if let host = miniPlayer!.glassContainer.superview {
      compactWidthConstraint = miniPlayer!.glassContainer.widthAnchor
        .constraint(equalTo: host.widthAnchor)
    }

    miniPlayer!.tabAccessoryTraitChangeCB = configureTraitChangesForMiniPlayer
    configureTraitChangesForMiniPlayer()

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
        self.configureTraitChangesForMiniPlayer()
      }
    )

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder", message: "Offline Mode is active.")
    }
  }

  // MARK: - Rail reveal

  /// cassette (rail): what the platform does, measured on 2026-10-19 with a
  /// completely stock UITabBarController on the iOS 26.4 simulator: with
  /// `.onScrollDown` the bar minimizes on a scroll down and comes back ONLY when
  /// the content reaches the top. A short flick up, a slow 300pt drag up and a
  /// 600pt drag up mid-list all leave it minimized. Reddit's bar comes back on
  /// the first upward movement, which is the feel the founder wants, so the
  /// reveal is ours and the minimize stays UIKit's:
  ///
  /// - an upward run of `railRevealDistance` points (while not at the top) sets
  ///   `.never`, which makes UIKit expand the bar at once;
  /// - `railRearmDelay` later, once that animation is done, the behaviour goes
  ///   back to `.onScrollDown`, and UIKit minimizes again on the next downward
  ///   drag (measured: it decides per drag, so handing it back mid-drag does
  ///   nothing until the finger lifts).
  ///
  /// One flip pair per upward run, hysteresis in points, no direction-flip
  /// cooldowns. The old version flipped on every sub-pixel reversal behind
  /// timers, which is where the stutter came from.
  private var railRunStartY: CGFloat = 0
  private var railLastY: CGFloat = 0
  private var railLastDirectionDown = true
  private var railRevealedThisRun = false
  private var railRearmWorkItem: DispatchWorkItem?
  private static let railRevealDistance: CGFloat = 12
  private static let railRearmDelay: TimeInterval = 0.4
  private static let railSettleDelay: TimeInterval = 0.35

  /// cassette (rail): at the very end of a list UIKit toggles the bar by
  /// itself on the first downward points of a drag (measured on 26.4: a 16pt
  /// first tick flips it either way, minimized or expanded). A finger landing
  /// to scroll back up can give exactly that, which collapsed an expanded bar
  /// for a beat before the reveal brought it back. So while a list rests
  /// against its end with the bar out, the behaviour is `.never`. It goes back
  /// to `.onScrollDown` on the first touch that lands anywhere else (UIKit
  /// reads the behaviour per drag, so that has to happen before a drag can
  /// start), or once the content has moved up by `railRevealDistance`.
  private var railBottomHold = false
  private weak var railBottomHoldScrollView: UIScrollView?

  #if DEBUG
  /// Launch with `-railTrace` and read the `[rail]` lines in the console.
  static let railTraceEnabled = ProcessInfo.processInfo.arguments.contains("-railTrace")
  static func railTrace(_ line: @autoclosure () -> String) {
    guard railTraceEnabled else { return }
    print(String(format: "[rail] %.3f ", ProcessInfo.processInfo.systemUptime) + line())
  }
  private var railDebugWasTracking = false
  #endif

  private static func railMaxY(_ scrollView: UIScrollView) -> CGFloat {
    scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
      - scrollView.bounds.height + scrollView.adjustedContentInset.top
  }

  private func railHoldAtBottom(_ scrollView: UIScrollView) {
    guard !railBottomHold else { return }
    railBottomHold = true
    railBottomHoldScrollView = scrollView
    railRearmWorkItem?.cancel()
    tabBarMinimizeBehavior = .never
    #if DEBUG
    Self.railTrace("HOLD at the end of the list")
    #endif
  }

  private func railReleaseBottomHold(_ why: String) {
    guard railBottomHold else { return }
    railBottomHold = false
    railBottomHoldScrollView = nil
    tabBarMinimizeBehavior = .onScrollDown
    #if DEBUG
    Self.railTrace("RELEASE hold: \(why)")
    #endif
  }

  /// Every touch-down on the screen, before any drag can start.
  fileprivate func railTouchDown(at point: CGPoint) {
    guard railBottomHold else { return }
    guard let held = railBottomHoldScrollView,
          let hit = view.hitTest(point, with: nil), hit.isDescendant(of: held),
          held.contentOffset.y + held.adjustedContentInset.top >= Self.railMaxY(held) - 1
    else {
      railReleaseBottomHold("touch elsewhere")
      return
    }
  }

  func cassetteUpdateMinimizeForScroll(_ scrollView: UIScrollView) {
    let topInset = scrollView.adjustedContentInset.top
    let y = scrollView.contentOffset.y + topInset
    let maxY = Self.railMaxY(scrollView)
    // Only the user's own movement counts: programmatic offsets (reloads, the
    // keyboard, a content-inset change) must not flip the bar.
    guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else {
      if railBottomHold, scrollView === railBottomHoldScrollView,
         y < maxY - Self.railRevealDistance {
        railReleaseBottomHold("moved off the end")
      }
      railLastY = y
      railRunStartY = y
      railRevealedThisRun = false
      return
    }
    if railBottomHold, scrollView !== railBottomHoldScrollView {
      railReleaseBottomHold("another list")
    }
    let dy = y - railLastY
    railLastY = y
    #if DEBUG
    if scrollView.isTracking != railDebugWasTracking {
      railDebugWasTracking = scrollView.isTracking
      Self.railTrace("\(scrollView.isTracking ? "FINGER-DOWN" : "FINGER-UP") y=\(Int(y)) maxY=\(Int(maxY)) dy=\(String(format: "%.1f", dy)) layout=\(String(describing: appliedRailLayout)) behavior=\(tabBarMinimizeBehavior.rawValue) hold=\(railBottomHold)")
    }
    #endif
    // Outside the content, in either direction, nothing counts: at the top
    // UIKit expands on its own, and at the bottom the rubber band snapping back
    // is not the person scrolling up. That snap-back used to fire the reveal
    // while UIKit was still minimizing, and the bar got stuck half way
    // (expanded pill, inline mini player).
    if y <= 0 || y >= maxY {
      if y >= maxY, appliedRailLayout != .inline {
        railHoldAtBottom(scrollView)
      }
      railRunStartY = y
      railRevealedThisRun = false
      return
    }
    if railBottomHold, y < maxY - Self.railRevealDistance {
      railReleaseBottomHold("scrolled up from the end")
    }
    guard dy != 0 else { return }
    let movingDown = dy > 0
    if movingDown != railLastDirectionDown {
      railLastDirectionDown = movingDown
      railRunStartY = y
      railRevealedThisRun = false
    }
    guard !movingDown, !railRevealedThisRun, y - railRunStartY <= -Self.railRevealDistance
    else { return }
    // Let a minimize that has just started finish before asking for the
    // opposite; flipping mid-animation is what left the bar half way.
    guard ProcessInfo.processInfo.systemUptime - railWentInlineAt > Self.railSettleDelay
    else { return }
    // Nothing to reveal when the bar is already out. At the end of a list
    // UIKit often brings it back by itself on the bounce; setting `.never`
    // on an expanded bar then made it re-run its expansion, which read as a
    // flash on the next scroll up from the bottom.
    guard appliedRailLayout == .inline else { return }
    railRevealedThisRun = true
    #if DEBUG
    Self.railTrace("REVEAL y=\(Int(y)) maxY=\(Int(maxY)) runStart=\(Int(railRunStartY))")
    #endif
    railRearmWorkItem?.cancel()
    tabBarMinimizeBehavior = .never
    let rearm = DispatchWorkItem { [weak self] in
      guard let self, !self.railBottomHold else { return }
      self.tabBarMinimizeBehavior = .onScrollDown
    }
    railRearmWorkItem = rearm
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.railRearmDelay, execute: rearm)
  }

  private func mainContent() -> UIView {
    // Attempt to find the main content view controller's view if the sidebar is visible.
    // Fallback to self.view.safeAreaLayoutGuide.leadingAnchor otherwise.
    if traitCollection.horizontalSizeClass == .regular, let selectedViewController {
      return selectedViewController.view
    }
    return view
  }

  var centerConstraint: NSLayoutConstraint?
  var regularWidthConstraint: NSLayoutConstraint?
  var heightConstraint: NSLayoutConstraint?
  var compactWidthConstraint: NSLayoutConstraint?
  var inlineHeightConstraint: NSLayoutConstraint?

  private enum RailLayout: Equatable { case inline, regularWide(CGFloat), compact }
  private var appliedRailLayout: RailLayout?
  private var railWentInlineAt: TimeInterval = 0

  func configureTraitChangesForMiniPlayer() {
    guard let miniPlayer else { return }
    // cassette (rail): ONE read of the accessory trait decides both the
    // container constraints here and the pill's own layout, and both are
    // idempotent, so UIKit's minimize/expand animation is never fought by a
    // constraint pass that disagrees with it halfway through.
    let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline
    let wanted: RailLayout
    if isInline {
      wanted = .inline
    } else if traitCollection.horizontalSizeClass == .regular {
      let mainContentView = mainContent()
      let playerWidth = min(
        mainContentView.frame.width - mainContentView.safeAreaInsets.left
          - mainContentView.safeAreaInsets.right,
        600
      )
      wanted = .regularWide(playerWidth)
    } else {
      wanted = .compact
    }
    miniPlayer.applyTabAccessoryLayout(isInline: isInline)
    guard wanted != appliedRailLayout else { return }
    if isInline, appliedRailLayout != nil {
      // A minimize just started; the reveal rule waits for it to settle.
      railWentInlineAt = ProcessInfo.processInfo.systemUptime
    }
    #if DEBUG
    Self.railTrace("LAYOUT \(String(describing: appliedRailLayout)) -> \(wanted) behavior=\(tabBarMinimizeBehavior.rawValue)")
    #endif
    appliedRailLayout = wanted

    switch wanted {
    case .inline:
      // Inline means inside the minimized tab bar, where the system sizes the
      // accessory slot. Fill the slot it gives: width AND height from the
      // host, no fixed 48.
      heightConstraint?.isActive = false
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
      if inlineHeightConstraint == nil, let host = miniPlayer.glassContainer.superview {
        inlineHeightConstraint = miniPlayer.glassContainer.heightAnchor
          .constraint(equalTo: host.heightAnchor)
      }
      inlineHeightConstraint?.isActive = true
    case let .regularWide(playerWidth):
      inlineHeightConstraint?.isActive = false
      centerConstraint?.isActive = false
      centerConstraint = miniPlayer.glassContainer.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      regularWidthConstraint = miniPlayer.glassContainer.widthAnchor
        .constraint(equalToConstant: playerWidth)
      regularWidthConstraint?.isActive = true
      centerConstraint?.isActive = true
      heightConstraint?.constant = 60.0
      heightConstraint?.isActive = true
    case .compact:
      inlineHeightConstraint?.isActive = false
      heightConstraint?.constant = 48.0
      heightConstraint?.isActive = true
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    }

    miniPlayer.glassContainer.setNeedsLayout()
    miniPlayer.glassContainer.layoutIfNeeded()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    configureTraitChangesForMiniPlayer()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    refresh()
    selectedTab = homeTab
    // cassette Patch 053 (Phase H): the initial selection in viewIsAppearing
    // does not fire `tabBarController(_:didSelectTab:previousTab:)`, so we
    // sync the filled-vs-outline icon swap manually for first paint.
    applySelectedTabIcon(selected: selectedTab)
    welcomePopupPresenter.displayInfoPopupsIfNeeded()
  }

  // cassette Patch 053 (Phase H): swap the selected tab's image to its
  // filled variant and reset every other root tab to its outline variant.
  // This is the structural selection cue that replaces the prior color-
  // only differentiation (selected glyph was orange-tinted; now selected =
  // filled SF Symbol, inactive = outline). For LibraryDisplayType items
  // without a filled SF Symbol pair (artists, songs, playlists, etc.),
  // `image` and `outlineImage` are identical so the only selection cue is
  // the existing label weight bump (semibold -> bold) set in CassetteTheme.
  private func applySelectedTabIcon(selected: UITab?) {
    if let homeTab {
      homeTab
        .image = (homeTab === selected) ? TabNavigatorItem.home.selectedIcon : TabNavigatorItem
        .home
        .outlineIcon
    }
    if let libraryGroup {
      // The library group itself is selectable as the "Library" entry.
      libraryGroup.image = (libraryGroup === selected) ? .musicLibrary : .musicLibraryOutline
      // When a descendant library category is the selected tab, also flip
      // that tab's icon to filled and reset its siblings to outline.
      for child in libraryGroup.children {
        guard let item = LibraryDisplayType.createByDisplayName(name: child.title) else { continue }
        child.image = (child === selected) ? item.image : item.outlineImage
      }
    }
    if let searchTab {
      // Search has no filled/outline SF Symbol pair; weight bump on the
      // selected label (set in CassetteTheme.applyGlobalAppearance) is the
      // structural cue for that tab.
      searchTab
        .image = (searchTab === selected) ? TabNavigatorItem.search.selectedIcon : TabNavigatorItem
        .search
        .outlineIcon
    }
  }

  @objc
  func handleLibraryItemsChanged(notification: Notification) {
    refresh()
  }

  func refresh() {
    guard let libraryGroup else { return }
    let config = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .libraryDisplaySettings
    libraryGroup.displayOrderIdentifiers = config.inUse.compactMap { "Tabs.\($0.displayName)" }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if let _ = config.inUse.first(where: { $0 == item }) {
        tab.isHidden = false
      } else {
        tab.isHidden = true
      }
    }
  }

  public func push(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
    selectedTab = libraryGroup
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  // cassette Patch 053 (Phase H): iOS 18+ tab selection callback. Fires
  // after the user taps any root tab or any descendant in a UITabGroup;
  // we use it to swap the structural filled/outline icon for the newly
  // selected tab and reset its siblings.
  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelectTab selectedTab: UITab,
    previousTab: UITab?
  ) {
    applySelectedTabIcon(selected: selectedTab)
  }

  func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
    var visibleItems = [LibraryDisplayType]()
    guard let libraryGroup else { return }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if !tab.isHidden {
        visibleItems.append(item)
      }
    }
    appDelegate.storage.settings.accounts
      .updateSetting(account.info) { accountSettings in
        accountSettings.libraryDisplaySettings = LibraryDisplaySettings(inUse: visibleItems)
      }
    NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil, userInfo: nil)
  }
}

// MARK: MainSceneHostingViewController

extension TabBarVC: MainSceneHostingViewController {
  public func pushNavLibrary(vc: UIViewController) {
    push(vc: vc)
  }

  public func pushLibraryCategory(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.popToRootViewController(animated: false)
    push(vc: vc)
  }

  /// cassette Patch 042: deep-link from Home shelf headers into a
  /// specific Library category. Pops any pushed detail views off
  /// the Library nav stack, asks the root LibraryContainerVC to
  /// switch its dropdown, and selects the Library tab so the user
  /// lands on the requested category in one tap.
  public func switchToLibrary(category: LibraryDisplayType) {
    guard let libraryGroup else { return }
    let nav = libraryGroup.managingNavigationController
    nav?.popToRootViewController(animated: false)
    if let container = nav?.viewControllers.first as? LibraryContainerVC {
      container.showCategory(category)
    }
    selectedTab = libraryGroup
  }

  func pushTabCategory(tabCategory: TabNavigatorItem) {
    switch tabCategory {
    case .home:
      selectedTab = homeTab
    case .search:
      selectedTab = searchTab
    }
    configureTraitChangesForMiniPlayer()
  }

  func displaySearch() {
    guard let searchTab else { return }
    visualizePopupPlayer(direction: .close, animated: true) {
      self.selectedTab = searchTab
      searchTab.viewController?.navigationController?.popToRootViewController(animated: false)
      Task {
        try await Task.sleep(nanoseconds: 500_000_000)
        if let searchTabVC = searchTab.viewController?.navigationController?
          .topViewController as? SearchVC {
          searchTabVC.activateSearchBar()
        }
      }
    }
  }

  func getSafeAreaExtension() -> CGFloat {
    0.0
  }
}

// MARK: - Rail touch-down observer

/// cassette (rail): sees every touch-down on the tab bar controller's view
/// without taking part in it. `TabBarVC.railTouchDown(at:)` uses it to hand
/// the minimize behaviour back before a drag can start somewhere else.
private final class RailTouchDownObserver: UIGestureRecognizer {
  private let onTouchDown: (CGPoint) -> Void

  init(onTouchDown: @escaping (CGPoint) -> Void) {
    self.onTouchDown = onTouchDown
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first, let view {
      onTouchDown(touch.location(in: view))
    }
    state = .failed
  }
}
