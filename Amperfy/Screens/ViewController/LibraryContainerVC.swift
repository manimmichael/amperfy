//
//  LibraryContainerVC.swift
//  Amperfy
//
//  Created by Cassette Patch 039.
//  Copyright (c) 2026 Cassette. All rights reserved.
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

// MARK: - LibraryContainerVC

/// cassette Patch 039: Library tab redesign. Replaces `LibraryVC`'s
/// intermediate category list. Opens directly to the user's last-
/// surfaced category, hosts a nav-bar dropdown for switching, and
/// inherits each category VC's native `UISearchController` so the
/// pull-down search keeps working in place.
///
/// `LibraryVC` is intentionally kept on disk — `pushLibraryCategory`
/// and other deep-link flows still rely on `segueToLibrary`.
@MainActor
final class LibraryContainerVC: UIViewController {
  // MARK: - Dropdown surface

  /// The categories that surface in the dropdown. Mirrors the
  /// shipping iOS information architecture; favorites / newest /
  /// recent / directories / downloads are deliberately excluded per
  /// spec (still reachable via the existing tab sub-items and the
  /// Mac sidebar's `LibraryNavigatorConfigurator`).
  /// cassette Patch 104: Radios is disabled for now — removed from the
  /// iOS dropdown only (the Mac sidebar configurator is untouched). A
  /// stale persisted `.radios` selection falls back to Artists via the
  /// allow-list check in `init`.
  /// cassette: Podcasts is hidden as a browse surface — dropped from the
  /// iOS dropdown. A stale persisted `.podcasts` selection falls back to
  /// Artists via the same allow-list check in `init` / `showCategory`.
  private static let dropdownCategories: [LibraryDisplayType] = [
    .artists,
    .albums,
    .songs,
    .playlists,
    .genres,
  ]

  // MARK: - State

  private let account: Account
  private var currentCategory: LibraryDisplayType
  private var embeddedChild: UIViewController?

  private var titleButton: UIButton?
  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private var accountNotificationHandler: AccountNotificationHandler?

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    let persisted = appDelegate.storage.settings.accounts
      .getSetting(account.info).read.lastLibraryCategory
    // Defensive fallback: if a stale persisted enum case isn't in
    // our dropdown allow-list (e.g. user previously deep-linked
    // into Downloads and we then renamed cases), reset to Artists.
    if Self.dropdownCategories.contains(persisted) {
      self.currentCategory = persisted
    } else {
      self.currentCategory = .artists
    }
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = CassetteTheme.UIColors.bg
    // The dropdown lives in `titleView`; we never want the navbar
    // to inflate to large-title height because the embedded VCs
    // are doing their own scroll-driven UI underneath us.
    navigationItem.largeTitleDisplayMode = .never

    setupTitleButton()

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] _ in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem
      )
    }
    setupUserNavButton(
      currentAccount: account,
      userButton: &userButton,
      userBarButtonItem: &userBarButtonItem
    )

    embedChild(category: currentCategory)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Override the child's own viewWillAppear which flips this on;
    // dropdown lives in titleView so large-title mode would just
    // squash our content under a doubled-up bar.
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  // MARK: - Title button + dropdown

  private func setupTitleButton() {
    // cassette Patch 104 (Root 1): UIButton(configuration:) + cassetteBare()
    // instead of UIButton(type: .system) + .plain() — the system-button
    // default picked up the iOS 26 glass capsule and drew a faint rounded
    // container behind the "Artists v" dropdown.
    let button = UIButton(configuration: .cassetteBare())
    button.showsMenuAsPrimaryAction = true
    button.menu = makeCategoryMenu()
    applyTitleButtonAppearance(button: button, label: currentCategory.displayName)
    titleButton = button
    navigationItem.titleView = button
  }

  private func applyTitleButtonAppearance(button: UIButton, label: String) {
    var config = UIButton.Configuration.cassetteBare()
    var titleContainer = AttributeContainer()
    titleContainer.font = UIFont.cassette(.sectionTitle)
    titleContainer.foregroundColor = CassetteTheme.UIColors.ink
    config.attributedTitle = AttributedString(label, attributes: titleContainer)
    config.image = UIImage(systemName: "chevron.down")
    config.imagePlacement = .trailing
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 12,
      weight: .semibold
    )
    config.imagePadding = 6
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    // cassette Polish 2 (C4/H): Barlow Condensed Bold at 22pt has a tall
    // bounding box; with zero vertical insets + sizeToFit the glyph tops were
    // clipped in the nav titleView. Give the line vertical breathing room.
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
    button.configuration = config
    button.tintColor = CassetteTheme.UIColors.ink
    // Force the button to size itself so the chevron sits next to
    // the title rather than centered awkwardly.
    button.sizeToFit()
  }

  private func makeCategoryMenu() -> UIMenu {
    let actions = Self.dropdownCategories.map { type -> UIAction in
      UIAction(
        title: type.displayName,
        image: type.image,
        state: type == currentCategory ? .on : .off,
        handler: { [weak self] _ in
          self?.switchCategory(type)
        }
      )
    }
    return UIMenu(title: "Library", children: actions)
  }

  // MARK: - Child embedding

  private func embedChild(category: LibraryDisplayType) {
    let child = category.controller(
      account: account,
      settings: appDelegate.storage.settings
    )
    // Force `viewDidLoad` on the child so its search controller and
    // right-bar buttons exist before we copy them through. Each
    // shipping category VC sets up `navigationItem.searchController`
    // in `viewDidLoad` (see `configureSearchController` in
    // `BasicTableViewController`).
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.topAnchor.constraint(equalTo: view.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    child.didMove(toParent: self)
    embeddedChild = child

    // Copy nav-bar surface up to the container. We never display
    // the child's own navigation bar — the container owns the bar.
    navigationItem.searchController = child.navigationItem.searchController
    navigationItem.hidesSearchBarWhenScrolling = true
    navigationItem.rightBarButtonItems = child.navigationItem.rightBarButtonItems
    definesPresentationContext = true
  }

  private func unembedCurrentChild() {
    guard let child = embeddedChild else { return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
    embeddedChild = nil
    navigationItem.searchController = nil
    navigationItem.rightBarButtonItems = nil
  }

  // MARK: - Category switching

  /// cassette Patch 042: external entry point for deep-linking into
  /// a specific Library category (e.g. tapping the Albums shelf
  /// header on Home). Mirrors the private `switchCategory(_:)` but
  /// guards against unknown enum cases the dropdown doesn't surface.
  public func showCategory(_ type: LibraryDisplayType) {
    guard Self.dropdownCategories.contains(type) else { return }
    switchCategory(type)
  }

  private func switchCategory(_ type: LibraryDisplayType) {
    guard type != currentCategory else { return }
    currentCategory = type

    if let accountInfo = appDelegate.storage.settings.accounts.active {
      appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
        accountSettings.lastLibraryCategory = type
      }
    }

    unembedCurrentChild()
    embedChild(category: type)

    if let titleButton {
      applyTitleButtonAppearance(button: titleButton, label: type.displayName)
      // Rebuild menu so the new selection's `.on` state reflects
      // immediately on next open.
      titleButton.menu = makeCategoryMenu()
    }
  }
}

extension LibraryContainerVC {
  override var sceneTitle: String? { "Library" }
}
