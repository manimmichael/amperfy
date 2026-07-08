//
//  AccountSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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
import SwiftUI

// MARK: - AccountSettingsView

struct AccountSettingsView: View {
  let splitPercentage = 0.25

  @State
  var isPwUpdateDialogVisible = false
  @State
  var isShowLogoutAlert = false
  @State
  var isShowResyncLibraryAlert = false
  @EnvironmentObject
  var settings: Settings

  func setThemePreference(preference: ThemePreference) {
    // cassette Patch 052 (Phase G): theme color pins to ink explicitly. The
    // ThemePreference enum is retained for Core Data migration safety but
    // all cases resolve to ink (SettingEnumerations.asColor); doing this
    // explicitly removes the indirection.
    settings.themePreference = preference
    appDelegate.setAppTheme(color: CassetteTheme.UIColors.ink)
    appDelegate.applyAppThemeToAlreadyLoadedViews()
  }

  private func resyncLibrary(accountInfo: AccountInfo) {
    appDelegate.closeAllButActiveMainTabs()
    if appDelegate.storage.settings.accounts.allAccounts.count <= 1 {
      appDelegate.stopForInit()
    }

    let meta = appDelegate.getMeta(accountInfo)
    meta.stopManager()
    appDelegate.resetMeta(accountInfo)

    // reset quick actions
    appDelegate.quickActionsManager.configureQuickActions()
    appDelegate.configureMainMenu()

    appDelegate.storage.settings.user.isOfflineMode = false
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    appDelegate.player.logout(account: account)
    let syncVC = AppStoryboard.Main.segueToSync(account: account)
    syncVC.modalPresentationStyle = .formSheet
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.dismiss(animated: false)
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.present(syncVC, animated: true)
  }

  private func logout(accountInfo: AccountInfo) {
    // Patch 111 (5): teardown extracted to AppDelegate.logoutAccount so the
    // profile menu's "Log Out" reuses the exact same flow.
    appDelegate.logoutAccount(accountInfo)
  }

  /// cassette: a Cassette-paired account's Subsonic login is a `cassette-*`
  /// machine credential the desktop Player mints AND manages automatically at
  /// pairing. The stock "Update Password" screen is LOCAL-ONLY — it changes
  /// Navidrome + the on-device keychain but never the cloud — so a manual change
  /// here silently diverges from the authoritative cloud credential and breaks on
  /// the next re-pair. Hide it for Cassette accounts; manual (generic Subsonic)
  /// accounts still get it.
  private func isCassetteAccount(_ info: AccountInfo) -> Bool {
    (appDelegate.storage.settings.accounts.getSetting(info).read
      .loginCredentials?.username ?? "").hasPrefix("cassette-")
  }

  var body: some View {
    ZStack {
      SettingsList {
        if let activeAccountInfo = settings.activeAccountInfo {
          // cassette polish Part 6: server URL, transcoding, scrobble, Auto
          // Cache, backend/API-version rows, and Manage Server URLs are hidden.
          // Pairing owns the connection; protocol details don't surface here.
          // cassette: this row used to show the raw Subsonic machine login
          // (loginCredentials.username, e.g. "cassette-qsvdgam0") — a device
          // credential the desktop mints at pairing, NOT the user's identity, which
          // read as "that is not my username". Show the real Cassette account
          // instead: name, then email — the same identity the account menu already
          // leads with (CassetteSyncAPI, sourced from /api/sync/account). Falls back
          // to "Connected" before the first sync lands, and never surfaces the token.
          SettingsSection {
            SettingsRow(
              title: "Account",
              orientation: .vertical,
              splitPercentage: splitPercentage
            ) {
              SecondaryText(CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail ?? "Connected")
            }
            if CassetteSyncAPI.accountName != nil,
               let email = CassetteSyncAPI.accountEmail {
              SettingsRow(
                title: "Email",
                orientation: .vertical,
                splitPercentage: splitPercentage
              ) {
                SecondaryText(email)
              }
            }
          }

          SettingsSection {
            if !isCassetteAccount(activeAccountInfo) {
              SettingsButtonRow(title: "Update Password") {
                withPopupAnimation { isPwUpdateDialogVisible = true }
              }
            }
            SettingsButtonRow(title: "Resync Library") {
              isShowResyncLibraryAlert = true
            }.alert(isPresented: $isShowResyncLibraryAlert) {
              Alert(
                title: Text("Resync Library"),
                message: Text(
                  "This will reset your local library and start syncing again from the server. Your downloaded files will remain on this device.\n\nDo you want to resync your library?"
                ),
                primaryButton: .destructive(Text("Resync")) {
                  resyncLibrary(accountInfo: activeAccountInfo)
                },
                secondaryButton: .cancel()
              )
            }
          }

          SettingsSection {
            SettingsButtonRow(title: "Logout", actionType: .destructive) {
              isShowLogoutAlert = true
            }
            .alert(isPresented: $isShowLogoutAlert) {
              Alert(
                title: Text("Logout"),
                message: Text(
                  "Logging out will sign you out of the current account. Your login credentials will be removed, and all downloaded files for this account will be deleted.\n\nDo you want to log out?"
                ),
                primaryButton: .destructive(Text("Logout")) {
                  logout(accountInfo: activeAccountInfo)
                },
                secondaryButton: .cancel()
              )
            }
          }
        } else {
          // User is not logged in yet
          SettingsSection {
            SecondaryText("You aren't logged in yet.")
          }
        }
      }
    }
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $isPwUpdateDialogVisible) {
      UpdatePasswordView(isVisible: $isPwUpdateDialogVisible)
    }
  }
}

// MARK: - AccountSettingsView_Previews

struct AccountSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    AccountSettingsView()
  }
}
