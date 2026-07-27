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
          title: cassetteAccountStatusLine(),
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
    // cassette: account avatar from /api/sync/account — photo when set, else
    // the chosen default (silhouette / initials / emoji). Silhouette is the
    // cream person.circle.fill glyph; web + Android match this mark.
    let size: CGFloat = {
      #if targetEnvironment(macCatalyst)
        return 50
      #else
        return 40
      #endif
    }()

    let button = UIButton(type: .custom)
    button.frame = CGRect(x: 0, y: 0, width: size, height: size)
    button.layer.cornerRadius = size / 2
    button.clipsToBounds = true
    button.setImage(Self.cassetteAccountAvatarImage(size: size), for: .normal)
    button.imageView?.contentMode = .scaleAspectFill
    button.contentHorizontalAlignment = .fill
    button.contentVerticalAlignment = .fill
    button.menu = createUserButtonMenu(extraLeadingMenuElements: extraLeadingMenuElements)
    button.showsMenuAsPrimaryAction = true
    userButton = button

    userBarButtonItem = UIBarButtonItem(customView: button)
    navigationItem.leftBarButtonItem = userBarButtonItem!

    // Photo loads async; swap in when ready so the chip updates without a relaunch.
    if let urlString = CassetteSyncAPI.accountImage, let url = URL(string: urlString) {
      Task { [weak button] in
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let photo = UIImage(data: data) else { return }
        await MainActor.run {
          button?.setImage(photo, for: .normal)
        }
      }
    }
  }

  /// Render the cached account avatar (preset or silhouette). Photo is loaded
  /// separately once the URL resolves.
  private static func cassetteAccountAvatarImage(size: CGFloat) -> UIImage {
    if CassetteSyncAPI.accountImage != nil {
      // Placeholder while the photo fetch lands — same silhouette as before.
      return silhouetteAvatar(size: size)
    }
    let preset = CassetteSyncAPI.accountAvatarPreset
    if preset == "initials" {
      let label = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail ?? "?"
      let initials = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        .uppercased()
      // Neutral grey disc — same family as the web IconButton key (--cs-bg3).
      return discAvatar(
        size: size,
        colors: [UIColor(red: 0.176, green: 0.157, blue: 0.125, alpha: 1)],
        text: initials.isEmpty ? "?" : initials,
        textColor: CassetteTheme.UIColors.ink
      )
    }
    if preset.hasPrefix("emoji:") {
      let emoji = String(preset.dropFirst("emoji:".count))
      if !emoji.isEmpty {
        return discAvatar(
          size: size,
          colors: [UIColor(red: 0.176, green: 0.157, blue: 0.125, alpha: 1)],
          text: emoji,
          textScale: 0.55,
          textColor: CassetteTheme.UIColors.ink
        )
      }
    }
    return silhouetteAvatar(size: size)
  }

  private static func silhouetteAvatar(size: CGFloat) -> UIImage {
    UIImage.userCircle(withConfiguration: UIImage.SymbolConfiguration(
      pointSize: size * 0.6,
      weight: .regular
    )).withTintColor(
      CassetteTheme.UIColors.ink,
      renderingMode: .alwaysOriginal
    )
  }

  private static func discAvatar(
    size: CGFloat,
    colors: [UIColor],
    text: String? = nil,
    textScale: CGFloat = 0.38,
    textColor: UIColor = .white
  ) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      let path = UIBezierPath(ovalIn: rect)
      path.addClip()
      if colors.count >= 2 {
        let gradient = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: colors.map(\.cgColor) as CFArray,
          locations: [0, 1]
        )!
        ctx.cgContext.drawLinearGradient(
          gradient,
          start: .zero,
          end: CGPoint(x: size, y: size),
          options: []
        )
      } else {
        colors.first?.setFill()
        path.fill()
      }
      if let text {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: size * textScale, weight: .semibold),
          .foregroundColor: textColor,
        ]
        let drawn = text as NSString
        let textSize = drawn.size(withAttributes: attrs)
        drawn.draw(
          at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
          withAttributes: attrs
        )
      }
    }
  }
}
