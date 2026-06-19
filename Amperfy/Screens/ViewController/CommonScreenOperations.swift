//
//  CommonScreenOperations.swift
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
import Foundation
import UIKit

extension UIView {
  static let defaultMarginX: CGFloat = 25
  static let defaultMarginY: CGFloat = 11
  static let defaultMarginTopElement = UIEdgeInsets(
    top: 0.0,
    left: UIView.defaultMarginX,
    bottom: 0.0,
    right: UIView.defaultMarginX
  )
  static let defaultMarginMiddleElement = UIEdgeInsets(
    top: UIView.defaultMarginY,
    left: UIView.defaultMarginX,
    bottom: UIView.defaultMarginY,
    right: UIView.defaultMarginX
  )
  static let defaultMarginCellX: CGFloat = 16
  static let defaultMarginCellY: CGFloat = 9
  static let defaultMarginCell = UIEdgeInsets(
    top: UIView.defaultMarginCellY,
    left: UIView.defaultMarginCellX,
    bottom: UIView.defaultMarginCellY,
    right: UIView.defaultMarginCellX
  )
}

// MARK: - CommonScreenOperations

class CommonScreenOperations {
  static let tableSectionHeightLarge: CGFloat = 40
  static let tableSectionHeightFooter: CGFloat = 8
}

// MARK: - UIViewController

extension UIViewController {
  /// cassette Patch 035: optional `extraLeadingMenuElements` lets a
  /// host VC (today: HomeVC) prepend screen-specific entries (e.g.
  /// "Edit Home") above the account picker without polluting the
  /// other tabs that share this menu.
  private func createUserButtonMenu(
    extraLeadingMenuElements: [UIMenuElement] = []
  )
    -> UIMenu {
    var accountActions = [UIMenuElement]()

    if !extraLeadingMenuElements.isEmpty {
      let extras = UIMenu(options: [.displayInline], children: extraLeadingMenuElements)
      accountActions.append(extras)
    }

    // cassette: de-jargoned account identity. The only handle the app holds is
    // the Subsonic `username` minted by the pairing flow ("cassette-qsvdgam0")
    // — a machine token, never a human name; the /api/player/me payload that
    // pairs a phone carries no display name or email (LoginVC). And multi-
    // account is not a Cassette concept: pairing binds ONE phone to ONE player
    // account (CassetteSyncAPI.registerDevice), so the upstream Amperfy
    // account-switcher / "Add Account" surface doesn't apply. We therefore show
    // a single, clean static "Cassette account" row (disabled, checked) for the
    // active account and drop both the account loop and "Add Account". (The
    // multi-account plumbing — allAccounts / switchAccount — stays in the
    // codebase for upstream parity; it's just not surfaced in this menu.)
    if appDelegate.storage.settings.accounts.active != nil {
      let accountLabel = UIAction(
        title: "Cassette account",
        image: .userCircle(withConfiguration: UIImage.SymbolConfiguration(
          pointSize: 30,
          weight: .regular
        )),
        attributes: [UIMenuElement.Attributes.disabled],
        state: .on,
        handler: { _ in }
      )
      accountActions.append(accountLabel)
    }

    let openSettings = UIAction(
      title: "Settings",
      image: .settings,
      handler: { _ in
        #if targetEnvironment(macCatalyst)
          self.appDelegate.showSettings(sender: "")
        #else
          let nav = AppStoryboard.Main.segueToSettings()
          nav.modalPresentationStyle = .formSheet
          self.present(nav, animated: true)
        #endif
      }
    )
    // Patch 111 (5): "Log Out" for the active account, reusing the shared
    // teardown (AppDelegate.logoutAccount) with a confirmation.
    // cassette: "Add Account" removed (see above) — this inline group is now
    // Log Out + Settings.
    var settingsChildren: [UIMenuElement] = []
    if let activeAccountInfo = appDelegate.storage.settings.accounts.active {
      let logoutAction = UIAction(
        title: "Log Out",
        image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
        attributes: .destructive,
        handler: { [weak self] _ in
          self?.confirmLogout(accountInfo: activeAccountInfo)
        }
      )
      settingsChildren.append(logoutAction)
    }
    settingsChildren.append(openSettings)
    let settingsMenu = UIMenu(options: [.displayInline], children: settingsChildren)
    accountActions.append(settingsMenu)

    return UIMenu(
      title: "",
      image: nil,
      options: [.displayInline],
      children: accountActions
    )
  }

  /// Patch 111 (5): confirm before the destructive account logout.
  private func confirmLogout(accountInfo: AccountInfo) {
    let username = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
      .loginCredentials?.username ?? "this account"
    let alert = UIAlertController(
      title: "Log Out",
      message: "Log out of \(username)? Downloaded files for this account will be removed from this device.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Log Out", style: .destructive, handler: { _ in
      self.appDelegate.logoutAccount(accountInfo)
    }))
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(alert, animated: true)
  }

  public func setupUserNavButton(
    currentAccount: Account,
    userButton: inout UIButton?,
    userBarButtonItem: inout UIBarButtonItem?,
    extraLeadingMenuElements: [UIMenuElement] = []
  ) {
    // cassette Patch 048 (Phase C): profile glyph pins to ink explicitly.
    // Patch 046 already flipped `themePreference.asColor` to ink so the prior
    // expression resolves to the same value, but pinning directly removes the
    // indirection (and the implicit dependency on per-account settings) for
    // this high-visibility nav button.
    let image = UIImage.userCircle(withConfiguration: UIImage.SymbolConfiguration(
      pointSize: 24,
      weight: .regular
    )).withTintColor(
      CassetteTheme.UIColors.ink,
      renderingMode: .alwaysTemplate
    )

    let button = UIButton(type: .system)
    button.setImage(image, for: .normal)
    button.layer.cornerRadius = 20
    button.clipsToBounds = true
    #if targetEnvironment(macCatalyst)
      button.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    #else
      button.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    #endif
    button.menu = createUserButtonMenu(extraLeadingMenuElements: extraLeadingMenuElements)
    button.showsMenuAsPrimaryAction = true
    userButton = button

    userBarButtonItem = UIBarButtonItem(customView: button)
    navigationItem.leftBarButtonItem = userBarButtonItem!
  }
}
