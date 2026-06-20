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
    // a single, non-interactive STATUS row for the active account and drop both
    // the account loop and "Add Account". (The multi-account plumbing —
    // allAccounts / switchAccount — stays in the codebase for upstream parity;
    // it's just not surfaced in this menu.)
    //
    // The row replaces the old static "Cassette account" string with a live
    // status: the Player's LAN host (the only human-ish identity we hold,
    // derived from loginCredentials.serverUrl / lanHostname) leads, followed by
    // connection state and sync freshness, e.g. "Michael's Mac · Synced 5m ago"
    // — or just "Connected" before the first poll lands.
    if appDelegate.storage.settings.accounts.active != nil {
      // Deferred so the relative sync time ("5m ago") is recomputed each time
      // the menu opens, not frozen at the moment the nav button was built.
      let accountStatusRow = UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self else { completion([]); return }
        let accountLabel = UIAction(
          title: self.cassetteAccountStatusLine(),
          image: .userCircle(withConfiguration: UIImage.SymbolConfiguration(
            pointSize: 30,
            weight: .regular
          )),
          attributes: [UIMenuElement.Attributes.disabled],
          handler: { _ in }
        )
        completion([accountLabel])
      }
      accountActions.append(accountStatusRow)
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

  // MARK: - Account status line (cassette)

  /// The non-interactive account-row status: "<Account> · Synced <rel>", e.g.
  /// "michaelin3d@icloud.com · Synced 5m ago". The lead is the user's Cassette
  /// ACCOUNT identity — the display NAME if the server returned one, else the
  /// account EMAIL — fetched by the sync poll (`CassetteSyncAPI.getAccount`)
  /// and persisted in UserDefaults. This is the account the bearer token
  /// authenticates as, NOT the paired Player's computer (its LAN hostname is
  /// only a last-ditch fallback for a never-synced install). Falls back to
  /// "Connected" when nothing is known yet, and omits the sync clause until
  /// the first successful poll has stamped `IntentExecutor.lastSyncAt`.
  /// Composed synchronously from cheap, already-on-device state (no network);
  /// connection here means "paired + bearer-token present" — the live sync
  /// timestamp is what conveys recent reachability.
  private func cassetteAccountStatusLine() -> String {
    let isConnected = appDelegate.storage.settings.accounts.active != nil
      && CassetteSyncAPI.bearerToken != nil
    let connectionWord = isConnected ? "Connected" : "Not connected"
    // Prefer the server-resolved ACCOUNT identity: name, else email. Only when
    // neither has been fetched yet do we fall back to the paired Player's
    // hostname (better than a bare "Connected" on a freshly paired, not-yet-
    // synced install), and finally to the connection word.
    let accountIdentity = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail
    let lead = accountIdentity ?? cassetteFriendlyPlayerName() ?? connectionWord
    // Whether the lead is a real identity (name/email/hostname) or just the
    // bare connection state — drives whether we append the connection word.
    let leadIsIdentity = accountIdentity != nil || cassetteFriendlyPlayerName() != nil

    guard let lastSyncAt = IntentExecutor.lastSyncAt else {
      // No poll has landed yet this install — no freshness to show. If an
      // identity led the row, append the bare connection state so it still
      // reads as a status; otherwise the lead already IS the connection state.
      return leadIsIdentity ? "\(lead) · \(connectionWord)" : lead
    }
    return "\(lead) · Synced \(cassetteRelativeSyncString(from: lastSyncAt))"
  }

  /// Best-effort human-readable Player name from the paired LAN server URL.
  /// `loginCredentials.serverUrl` is `http://<lanHostname>:<lanPort>` (LoginVC);
  /// `lanHostname` is a Bonjour host like "Michaels-MacBook-Pro.local" or a bare
  /// IP. We strip the scheme/port and a trailing ".local", and for a Bonjour
  /// name turn hyphens into spaces ("Michaels MacBook Pro"). A bare IP carries
  /// no human identity, so we return nil and the caller leads with "Connected".
  private func cassetteFriendlyPlayerName() -> String? {
    guard let serverUrl = appDelegate.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl,
      let host = URL(string: serverUrl)?.host, !host.isEmpty
    else { return nil }

    // Bare IPv4/IPv6 hosts aren't human-readable identities.
    let isIPv4 = host.split(separator: ".").count == 4
      && host.allSatisfy { $0.isNumber || $0 == "." }
    if isIPv4 || host.contains(":") { return nil }

    var name = host
    if name.lowercased().hasSuffix(".local") {
      name = String(name.dropLast(".local".count))
    }
    // Bonjour hostnames use hyphens for spaces; restore them for display.
    name = name.replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }

  /// Compact relative time for the sync line: "just now", "5m ago", "1h ago",
  /// "3d ago". Future/identical timestamps read as "just now".
  private func cassetteRelativeSyncString(from date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = Int(seconds / 3600)
    if hours < 24 { return "\(hours)h ago" }
    let days = Int(seconds / 86400)
    return "\(days)d ago"
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
