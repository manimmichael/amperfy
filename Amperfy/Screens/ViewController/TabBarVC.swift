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

    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    heightConstraint?.isActive = true
    compactWidthConstraint = miniPlayer!.glassContainer.widthAnchor
      .constraint(equalTo: miniPlayer!.glassContainer.superview!.widthAnchor)

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

  // cassette (manual eager reveal): iOS 26's tab bar only re-expands at the very
  // top with our nested navigation, and there's no imperative "expand" API. So we
  // drive `tabBarMinimizeBehavior` from scroll DIRECTION: scrolling UP flips it to
  // `.never` (which should un-minimize the bar immediately), scrolling DOWN flips
  // it back to `.onScrollDown` (so it minimizes again as you read on). Only toggles
  // on a real direction change past a small threshold, so a steady scroll doesn't
  // thrash the property.
  private var cassetteLastScrollY: CGFloat = 0
  private var cassetteLastToggleAt: TimeInterval = 0
  func cassetteUpdateMinimizeForScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let dy = y - cassetteLastScrollY
    cassetteLastScrollY = y

    // Asymmetric sensitivity (the "Reddit feel"): the bar should POP BACK on the
    // faintest upward flick — that's the motion users notice — but hide a little
    // more deliberately so a jittery downward read doesn't yank it away. Small
    // reveal threshold, larger hide threshold, a shallow dead-zone between them.
    let desired: UITabBarController.MinimizeBehavior
    if dy < -1.5 {
      desired = .never // scrolling UP → reveal
    } else if dy > 6 {
      desired = .onScrollDown // scrolling DOWN deliberately → allow minimize
    } else {
      return // dead-zone: sub-pixel jitter / direction unclear
    }
    guard tabBarMinimizeBehavior != desired else { return }

    // Anti-thrash cooldown: each behavior change animates the bar; hammering the
    // property on rapid reversals piles up animations and UIKit stalls ("tired
    // out"). Reveal gets a SHORTER cooldown so popping the bar back always feels
    // instant; hiding is rate-limited a touch more. The first toggle fires
    // immediately (cassetteLastToggleAt == 0); only a fast wiggle is throttled.
    let now = ProcessInfo.processInfo.systemUptime
    let cooldown: TimeInterval = desired == .never ? 0.18 : 0.30
    guard now - cassetteLastToggleAt > cooldown else { return }
    cassetteLastToggleAt = now
    tabBarMinimizeBehavior = desired
    #if DEBUG
    print("CASSETTE-NAV: \(desired == .never ? "REVEAL" : "hide") dy=\(String(format: "%.1f", dy))")
    #endif
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

  func configureTraitChangesForMiniPlayer() {
    guard let miniPlayer else { return }
    let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline

    if traitCollection.horizontalSizeClass == .regular {
      centerConstraint = miniPlayer.glassContainer.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      let mainContentView = mainContent()
      var playerWidth = mainContentView.frame.width - mainContentView.safeAreaInsets
        .left - mainContentView.safeAreaInsets.right
      playerWidth = min(playerWidth, 600)
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      regularWidthConstraint = miniPlayer.glassContainer.widthAnchor
        .constraint(equalToConstant: playerWidth)
      regularWidthConstraint?.isActive = true
      centerConstraint?.isActive = true
      heightConstraint?.constant = 60.0
    } else if isInline {
      heightConstraint?.constant = 48.0
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    } else {
      heightConstraint?.constant = 48.0
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
