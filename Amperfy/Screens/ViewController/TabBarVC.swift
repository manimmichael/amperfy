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

  /// cassette (rail, BUG-423): on the phone the bottom bar is ours
  /// (`CassetteRailView`, slid with the finger, see "Rail" below); on the iPad
  /// UIKit keeps its bar and the mini player rides as its accessory, as before.
  private var rail: CassetteRailView?

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UISearchTab { _ in
      let nav = UINavigationController(
        rootViewController: TabNavigatorItem.search
          .getController(account: self.account)
      )
      nav.delegate = self
      return nav
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
      let nav = UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
      nav.delegate = self
      return nav
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
    libraryGroup!.managingNavigationController?.delegate = self
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

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    miniPlayer!.glassContainer.translatesAutoresizingMaskIntoConstraints = false

    if traitCollection.userInterfaceIdiom == .phone {
      installCassetteRail()
    } else {
      installTabAccessory()
    }

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

  // MARK: - Rail (phone)

  /// cassette (rail, BUG-423): what the platform does, measured on the iOS
  /// 26.4 simulator with a completely stock UITabBarController: with
  /// `.onScrollDown` the bar minimizes on a downward drag and comes back only
  /// when the content reaches the top; it reads the behaviour once per drag;
  /// at the end of a list it toggles the bar by itself; its morph is a 0.47s
  /// crossfade of a snapshot that any behaviour change mid-flight reverses
  /// half-way; and the minimized bar gives the accessory no glass. Six commits
  /// of reveal rules, settle watchers and holds on top of that never felt like
  /// Reddit's bar, which follows the finger, because Reddit's bar is custom.
  ///
  /// So on the phone UIKit's bar is hidden (`isTabBarHidden`, behaviour
  /// `.never`, no accessory) and `CassetteRailView` draws the pill, the tab
  /// capsule and the search circle where the stock bar drew them. UIKit still
  /// owns the tabs and their view controllers; we own the pixels and the
  /// motion:
  ///
  /// - while the finger is down the rail translates with the content, point
  ///   for point, after `railHysteresis` of movement in a new direction (so a
  ///   jitter does not twitch it);
  /// - on lift it springs to rest in the direction the finger was going;
  /// - at the top of a list it is always out; the rubber band at the end, a
  ///   flick's deceleration and programmatic offsets (reloads, the keyboard)
  ///   move nothing, because the lift already decided;
  /// - a tab change or a push shows it.
  ///
  /// Every list already reports its scrolling to `cassetteUpdateMinimizeForScroll`
  /// (BasicTableViewController, BasicCollectionViewController, Home, the
  /// detail screens); the lift comes from the list's own pan recognizer.
  /// Launch with `-railTrace` (DEBUG) for `[rail]` lines in the console.
  private static let railHysteresis: CGFloat = 12
  private static let railSettleDuration: TimeInterval = 0.45
  private static let railSettleDamping: CGFloat = 0.86

  private weak var railScrollView: UIScrollView?
  private var railLastY: CGFloat = 0
  private var railSlack: CGFloat = 0
  private var railMovingDown = true
  private var railAnimator: UIViewPropertyAnimator?
  private var railSettleTarget: CGFloat?
  private let railObservedPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()

  /// Translating the rail by its own height puts all of it below the screen.
  private var railHiddenOffset: CGFloat { rail?.bounds.height ?? 0 }
  private var railOffset: CGFloat { rail?.transform.ty ?? 0 }

  #if DEBUG
    /// Launch with `-railTrace` and read the `[rail]` lines in the console.
    static let railTraceEnabled = ProcessInfo.processInfo.arguments.contains("-railTrace")
    static func railTrace(_ line: @autoclosure () -> String) {
      guard railTraceEnabled else { return }
      print(String(format: "[rail] %.3f ", ProcessInfo.processInfo.systemUptime) + line())
    }
  #endif

  private func installCassetteRail() {
    guard let miniPlayer, let homeTab, let libraryGroup else { return }
    // UIKit keeps the tabs; the pixels are ours.
    tabBarMinimizeBehavior = .never
    isTabBarHidden = true

    let rail = CassetteRailView(items: [
      CassetteRailView.Item(title: homeTab.title, image: TabNavigatorItem.home.outlineIcon),
      CassetteRailView.Item(title: libraryGroup.title, image: .musicLibraryOutline),
    ])
    rail.install(pill: miniPlayer.glassContainer)
    rail.onSelectItem = { [weak self] index in self?.railDidSelectItem(index) }
    rail.onSearch = { [weak self] in self?.railDidTapSearch() }
    view.addSubview(rail)
    NSLayoutConstraint.activate([
      rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      rail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.rail = rail
    // The last row of every list clears the pill. UIKit insets the content for
    // its own bar and accessory; with those gone the inset is ours.
    additionalSafeAreaInsets.bottom = CassetteRailView.contentInset
    railSyncSelection(animated: false)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    // The window's own bottom inset (the home indicator), without our addition.
    rail?.homeIndicatorInset = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
  }

  // MARK: Scroll

  /// Called by every scrolling screen from its `scrollViewDidScroll`.
  func cassetteUpdateMinimizeForScroll(_ scrollView: UIScrollView) {
    guard let rail else { return } // the iPad's bar is UIKit's
    railObservePan(of: scrollView)
    let top = scrollView.adjustedContentInset.top
    let y = scrollView.contentOffset.y + top
    let maxY = max(
      0,
      scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
        - scrollView.bounds.height + top
    )
    if scrollView !== railScrollView {
      // Another list: a fresh run, and out if it is at its top.
      railScrollView = scrollView
      railLastY = min(max(y, 0), maxY)
      railSlack = 0
      #if DEBUG
        Self.railTrace("LIST \(type(of: scrollView)) y=\(Int(y)) maxY=\(Int(maxY))")
      #endif
      if y <= 0 { railSettle(hidden: false) }
      return
    }
    let lastY = railLastY
    // Movement inside the rubber bands is not the person scrolling.
    railLastY = min(max(y, 0), maxY)
    // At the top the rail is always out: the end of a flick up, a reload,
    // scrollsToTop, a pull to refresh.
    if y <= 0 {
      railSlack = 0
      railSettle(hidden: false)
      return
    }
    // The finger is what the rail follows. A flick's deceleration and the
    // rubber band at the end decide nothing; the lift already did.
    guard scrollView.isTracking || scrollView.isDragging, y < maxY else { return }
    let dy = y - lastY
    guard dy != 0 else { return }
    let down = dy > 0
    if down != railMovingDown {
      railMovingDown = down
      railSlack = Self.railHysteresis
    }
    var distance = abs(dy)
    if railSlack > 0 {
      let used = min(railSlack, distance)
      railSlack -= used
      distance -= used
    }
    guard distance > 0 else { return }
    railStopAnimation()
    let next = min(max(railOffset + (down ? distance : -distance), 0), railHiddenOffset)
    if next != railOffset {
      rail.transform = CGAffineTransform(translationX: 0, y: next)
    }
  }

  private func railObservePan(of scrollView: UIScrollView) {
    let pan = scrollView.panGestureRecognizer
    guard !railObservedPans.contains(pan) else { return }
    railObservedPans.add(pan)
    pan.addTarget(self, action: #selector(railPanStateChanged(_:)))
  }

  /// The lift: a rail caught between its two rests springs to the one the
  /// finger was heading for, carrying the finger's speed.
  @objc
  private func railPanStateChanged(_ pan: UIPanGestureRecognizer) {
    guard pan.state == .ended || pan.state == .cancelled || pan.state == .failed else { return }
    guard rail != nil, let scrollView = pan.view as? UIScrollView,
          scrollView === railScrollView else { return }
    let offset = railOffset
    guard offset > 0, offset < railHiddenOffset else { return }
    let y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let hidden = y > 0 && railMovingDown
    // The content moves against the finger, and so does the rail.
    let velocity = -pan.velocity(in: scrollView).y
    #if DEBUG
      Self.railTrace("LIFT offset=\(Int(offset)) -> \(hidden ? "hidden" : "shown") v=\(Int(velocity))")
    #endif
    railSettle(hidden: hidden, velocity: velocity)
  }

  private func railSettle(hidden: Bool, velocity: CGFloat = 0) {
    guard let rail else { return }
    let target = hidden ? railHiddenOffset : 0
    if railAnimator != nil, railSettleTarget == target { return }
    railStopAnimation()
    let current = railOffset
    guard abs(current - target) > 0.5 else {
      if current != target {
        rail.transform = CGAffineTransform(translationX: 0, y: target)
      }
      return
    }
    let distance = abs(target - current)
    // The spring takes its starting speed as a fraction of the distance per
    // second, positive towards the target.
    let towards = (target > current ? velocity : -velocity) / distance
    let spring = UISpringTimingParameters(
      dampingRatio: Self.railSettleDamping,
      initialVelocity: CGVector(dx: 0, dy: min(max(towards, -20), 20))
    )
    let animator = UIViewPropertyAnimator(
      duration: Self.railSettleDuration,
      timingParameters: spring
    )
    animator.addAnimations {
      rail.transform = CGAffineTransform(translationX: 0, y: target)
    }
    animator.addCompletion { [weak self] _ in
      guard let self, self.railAnimator === animator else { return }
      self.railAnimator = nil
      self.railSettleTarget = nil
    }
    railSettleTarget = target
    railAnimator = animator
    animator.startAnimation()
  }

  /// A finger landing mid-spring takes over from wherever the rail is.
  private func railStopAnimation() {
    guard let animator = railAnimator else { return }
    railAnimator = nil
    railSettleTarget = nil
    if animator.state == .active {
      animator.stopAnimation(false)
      animator.finishAnimation(at: .current)
    }
  }

  // MARK: Tabs

  override var selectedTab: UITab? {
    didSet { railSyncSelection(animated: true) }
  }

  private func railSyncSelection(animated: Bool) {
    guard let rail else { return }
    var index: Int?
    if let selected = selectedTab {
      if selected === homeTab {
        index = 0
      } else if selected === libraryGroup || selected.parent === libraryGroup {
        index = 1
      }
    }
    rail.setSelectedItem(index, animated: animated && view.window != nil)
  }

  private func railDidSelectItem(_ index: Int) {
    guard let homeTab, let libraryGroup else { return }
    let tab: UITab = index == 0 ? homeTab : libraryGroup
    let nav = index == 0
      ? homeTab.viewController as? UINavigationController
      : libraryGroup.managingNavigationController
    #if DEBUG
      Self.railTrace("TAP \(tab.title)")
    #endif
    if selectedTab === tab || selectedTab?.parent === tab {
      // A second tap on the selected tab goes back to its root, as the stock
      // bar does.
      nav?.popToRootViewController(animated: true)
    } else {
      selectedTab = tab
    }
    railSettle(hidden: false)
  }

  private func railDidTapSearch() {
    guard let searchTab else { return }
    #if DEBUG
      Self.railTrace("TAP Search")
    #endif
    if selectedTab === searchTab {
      (searchTab.viewController as? UINavigationController)?
        .popToRootViewController(animated: true)
    } else {
      selectedTab = searchTab
    }
    railSettle(hidden: false)
    railActivateSearch()
  }

  /// The system's bar activated the search field when it selected the search
  /// tab; with that bar hidden the activation is ours, once the screen is up.
  private func railActivateSearch() {
    guard let searchTab else { return }
    Task { @MainActor in
      for _ in 0 ..< 12 {
        let nav = searchTab.viewController as? UINavigationController
          ?? searchTab.viewController?.navigationController
        if let searchVC = nav?.topViewController as? SearchVC,
           searchVC.isViewLoaded, searchVC.view.window != nil {
          searchVC.activateSearchBar()
          if searchVC.searchController.searchBar.isFirstResponder { return }
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
      }
    }
  }

  // MARK: - Tab accessory (iPad)

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

  private enum AccessoryLayout: Equatable { case inline, regularWide(CGFloat), compact }
  private var appliedAccessoryLayout: AccessoryLayout?

  /// The iPad keeps UIKit's bar, `.onScrollDown`, and the mini player as its
  /// bottom accessory, as before the phone's rail.
  private func installTabAccessory() {
    guard let miniPlayer else { return }
    tabBarMinimizeBehavior = .onScrollDown
    bottomAccessory = UITabAccessory(contentView: miniPlayer.glassContainer)

    heightConstraint = miniPlayer.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    // UIKit owns the accessory slot: everything we say about the pill's size
    // is a preference below required, so it can never fight the slot.
    heightConstraint?.priority = UILayoutPriority(999)
    heightConstraint?.isActive = true
    if let host = miniPlayer.glassContainer.superview {
      compactWidthConstraint = miniPlayer.glassContainer.widthAnchor
        .constraint(equalTo: host.widthAnchor)
      compactWidthConstraint?.priority = UILayoutPriority(999)
    }

    miniPlayer.tabAccessoryTraitChangeCB = configureTraitChangesForMiniPlayer
    configureTraitChangesForMiniPlayer()
  }

  func configureTraitChangesForMiniPlayer() {
    guard rail == nil, let miniPlayer else { return }
    // One read of the accessory trait decides the container constraints,
    // idempotently, so UIKit's own animation is never fought by a constraint
    // pass that disagrees with it halfway through.
    let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline
    let wanted: AccessoryLayout
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
    guard wanted != appliedAccessoryLayout else { return }
    appliedAccessoryLayout = wanted

    switch wanted {
    case .inline:
      // Inside the minimized bar the system sizes the slot; fill it both ways.
      heightConstraint?.isActive = false
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
      if inlineHeightConstraint == nil, let host = miniPlayer.glassContainer.superview {
        inlineHeightConstraint = miniPlayer.glassContainer.heightAnchor
          .constraint(equalTo: host.heightAnchor)
        inlineHeightConstraint?.priority = UILayoutPriority(999)
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
      regularWidthConstraint?.priority = UILayoutPriority(999)
      centerConstraint?.priority = UILayoutPriority(999)
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
    if let rail {
      view.bringSubviewToFront(rail)
    }
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
    railSyncSelection(animated: true)
    railSettle(hidden: false)
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

// MARK: UINavigationControllerDelegate

extension TabBarVC: UINavigationControllerDelegate {
  /// cassette (rail): a screen change brings the rail out, and the next list
  /// starts a fresh run.
  func navigationController(
    _ navigationController: UINavigationController,
    willShow viewController: UIViewController,
    animated: Bool
  ) {
    guard rail != nil else { return }
    railScrollView = nil
    railSettle(hidden: false)
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
      self.railActivateSearch()
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
