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

  // MARK: - Rail

  /// cassette (rail): what the platform does, measured on the iOS 26.4
  /// simulator with a completely stock UITabBarController:
  ///
  /// - with `.onScrollDown` the bar minimizes on a downward drag and comes back
  ///   only when the content reaches the top (a flick up and 300pt / 600pt
  ///   drags up mid-list leave it minimized);
  /// - it reads `tabBarMinimizeBehavior` once per drag, at the start, so a
  ///   change made mid-drag does nothing until the next drag;
  /// - at the very end of a list it toggles the bar by itself on the first
  ///   downward points of a drag, either way;
  /// - the morph between the two states is a crossfade of a snapshot, and a
  ///   change of behaviour that lands while it is in flight reverses it with a
  ///   snapshot of the half-way state (pill laid out for one state, sitting in
  ///   the other's slot), which is the "collapsed and broken for a beat" on a
  ///   fast swipe down then up.
  ///
  /// Reddit's bar comes back on the first upward movement, which is the feel
  /// the founder wants, so the reveal is ours and the minimize stays UIKit's.
  /// Two rules make that safe:
  ///
  /// 1. `tabBarMinimizeBehavior` is never written directly. `railWant(_:_:)`
  ///    records what we want; `railApplyIfSettled()` writes it only while the
  ///    bar is not moving, which a display link watches (`railMorphStarted`,
  ///    `railDisplayTick`, `railMorphSettled`) instead of a timer guessing at
  ///    the duration.
  /// 2. While a list rests against its end with the bar out, we want `.never`
  ///    (`railBottomHold`), handed back on the first touch that lands anywhere
  ///    else (before the drag UIKit will read it for), on a user scroll of
  ///    another list, or once the content has moved up by `railRevealDistance`.
  ///
  /// The reveal itself: an upward run of `railRevealDistance` points while the
  /// bar is inline wants `.never`; UIKit expands; when that settles we want
  /// `.onScrollDown` again and UIKit minimizes on the next downward drag.
  /// `railRevealEnabled = false` gives the stock behaviour (bar back at the top
  /// of a list only) with everything else unchanged.
  private static let railRevealEnabled = true
  private static let railRevealDistance: CGFloat = 12

  private var railRunStartY: CGFloat = 0
  private var railLastY: CGFloat = 0
  private var railLastDirectionDown = true
  private var railRevealedThisRun = false
  private var railBottomHold = false
  private weak var railBottomHoldScrollView: UIScrollView?

  private var railWanted: UITabBarController.MinimizeBehavior = .onScrollDown
  private var railMorphing = false
  private var railDisplayLink: CADisplayLink?
  private var railLastGeometry: [CGRect] = []
  private var railStillSince: TimeInterval = 0
  private var railMorphStartedAt: TimeInterval = 0
  private static let railStillWindow: TimeInterval = 0.08
  private static let railMorphTimeout: TimeInterval = 1.5

  #if DEBUG
  /// Launch with `-railTrace` and read the `[rail]` lines in the console.
  static let railTraceEnabled = ProcessInfo.processInfo.arguments.contains("-railTrace")
  static func railTrace(_ line: @autoclosure () -> String) {
    guard railTraceEnabled else { return }
    print(String(format: "[rail] %.3f ", ProcessInfo.processInfo.systemUptime) + line())
  }
  private var railDebugWasTracking = false
  #endif

  // MARK: Behaviour, written only while the bar is still

  private func railWant(_ behavior: UITabBarController.MinimizeBehavior, _ why: String) {
    railWanted = behavior
    #if DEBUG
    Self.railTrace("WANT \(behavior.rawValue) (\(why)) \(railMorphing ? "deferred, bar still moving" : "now")")
    #endif
    railApplyIfSettled()
  }

  private func railApplyIfSettled() {
    guard !railMorphing, tabBarMinimizeBehavior != railWanted else { return }
    tabBarMinimizeBehavior = railWanted
  }

  /// Called when the accessory moves between the inline slot and the floating
  /// position (see `configureTraitChangesForMiniPlayer`).
  private func railMorphStarted() {
    railMorphing = true
    railMorphStartedAt = ProcessInfo.processInfo.systemUptime
    railStillSince = 0
    railLastGeometry = []
    if railDisplayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(railDisplayTick(_:)))
      link.add(to: .main, forMode: .common)
      railDisplayLink = link
    }
  }

  @objc
  private func railDisplayTick(_ link: CADisplayLink) {
    let now = ProcessInfo.processInfo.systemUptime
    let geometry = railGeometry()
    let moved = geometry.count != railLastGeometry.count
      || zip(geometry, railLastGeometry).contains { a, b in
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
          || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
      }
    railLastGeometry = geometry
    if moved || railStillSince == 0 {
      railStillSince = now
    }
    if (!moved && now - railStillSince >= Self.railStillWindow)
      || now - railMorphStartedAt > Self.railMorphTimeout {
      railMorphSettled()
    }
  }

  /// On-screen (presentation) frames of the bar, the accessory slot and the
  /// pill, in window space.
  private func railGeometry() -> [CGRect] {
    var views: [UIView] = [tabBar]
    if let glass = miniPlayer?.glassContainer {
      views.append(glass)
      if let host = glass.superview { views.append(host) }
    }
    return views.map { view in
      let layer = view.layer.presentation() ?? view.layer
      return layer.convert(layer.bounds, to: nil)
    }
  }

  private func railMorphSettled() {
    railMorphing = false
    railDisplayLink?.invalidate()
    railDisplayLink = nil
    #if DEBUG
    Self.railTrace("SETTLED after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - railMorphStartedAt))s layout=\(String(describing: appliedRailLayout)) wanted=\(railWanted.rawValue)")
    #endif
    // A bar that has come out for a reveal goes back to UIKit's rule, unless
    // it is resting against the end of a list.
    if appliedRailLayout != .inline, !railBottomHold, railWanted == .never {
      railWanted = .onScrollDown
    }
    railApplyIfSettled()
  }

  // MARK: Hold at the end of a list

  private static func railMaxY(_ scrollView: UIScrollView) -> CGFloat {
    scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
      - scrollView.bounds.height + scrollView.adjustedContentInset.top
  }

  private func railHoldAtBottom(_ scrollView: UIScrollView) {
    guard !railBottomHold else { return }
    railBottomHold = true
    railBottomHoldScrollView = scrollView
    railWant(.never, "resting at the end of the list")
  }

  private func railReleaseBottomHold(_ why: String) {
    guard railBottomHold else { return }
    railBottomHold = false
    railBottomHoldScrollView = nil
    railWant(.onScrollDown, why)
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

  // MARK: Scroll rule

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
      Self.railTrace("\(scrollView.isTracking ? "FINGER-DOWN" : "FINGER-UP") y=\(Int(y)) maxY=\(Int(maxY)) dy=\(String(format: "%.1f", dy)) layout=\(String(describing: appliedRailLayout)) behavior=\(tabBarMinimizeBehavior.rawValue) wanted=\(railWanted.rawValue) morphing=\(railMorphing) hold=\(railBottomHold)")
    }
    #endif
    // Outside the content, in either direction, nothing counts: at the top
    // UIKit expands on its own, and at the bottom the rubber band snapping back
    // is not the person scrolling up.
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
      // A reveal still waiting for the bar to settle is stale once the person
      // scrolls down again.
      if movingDown, railWanted == .never, !railBottomHold, appliedRailLayout == .inline {
        railWant(.onScrollDown, "scrolled down before the reveal landed")
      }
    }
    guard Self.railRevealEnabled, !movingDown, !railRevealedThisRun,
          y - railRunStartY <= -Self.railRevealDistance
    else { return }
    // Nothing to reveal when the bar is already out, or already asked for.
    guard appliedRailLayout == .inline, railWanted != .never else { return }
    railRevealedThisRun = true
    #if DEBUG
    Self.railTrace("REVEAL y=\(Int(y)) maxY=\(Int(maxY)) runStart=\(Int(railRunStartY))")
    #endif
    railWant(.never, "reveal")
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
    #if DEBUG
    Self.railTrace("LAYOUT \(String(describing: appliedRailLayout)) -> \(wanted) behavior=\(tabBarMinimizeBehavior.rawValue)")
    #endif
    appliedRailLayout = wanted
    // The bar is about to move; nothing touches the behaviour until it stops.
    railMorphStarted()

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
