//
//  SettingsView.swift
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

// MARK: - SettingsView

// cassette §G: the settings root. Structure is Account · Playback · App Icon ·
// Storage, then Support · About · Advanced. Removed from this screen:
//   • Offline Mode — gone; cleared at launch (see AmperfyKit init). Owned-file
//     playback still works without a network.
//   • Prevent Screen Lock — gone; normal system lock (audio keeps playing).
//   • Server Mode toggle — gone; it becomes account-sourced (web owns the
//     write path; the phone reads it from the account payload — §C).
//   • Version / Build rows — moved to About.
struct SettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  func navigationLink(_ item: NavigationTarget) -> some View {
    NavigationLink(destination: AnyView(item.view())) {
      Text(item.displayName)
    }
  }

  var body: some View {
    let list =
      SettingsList {
        SettingsSection {
          navigationLink(.account)
          navigationLink(.playback)
          navigationLink(.appIcon)
          navigationLink(.storage)
        }

        SettingsSection {
          navigationLink(.support)
          navigationLink(.about)
          navigationLink(.advanced)

          #if DEBUG
            navigationLink(.developer)
          #endif
        }
      }

    #if targetEnvironment(macCatalyst) // ok
      ZStack {
        list
      }
      .navigationTitle("General")
      .navigationBarTitleDisplayMode(.inline)
    #else
      // cassette: NavigationStack (iOS 16+) replaces the deprecated NavigationView.
      // On iOS 26 the deprecated NavigationView renders a mis-styled opaque bar that
      // briefly covers the large "Settings" title and glitches/animates over the UI
      // on push into a sub-menu; NavigationStack adopts the Liquid Glass bar cleanly.
      NavigationStack {
        list
          .navigationTitle("Settings")
          // cassette: use the INLINE title on the Settings root. The large-title
          // (scroll-edge) state renders the global opaque nav-bar appearance
          // (CassetteTheme.applyGlobalAppearance → configureWithOpaqueBackground)
          // as a gray bar that covers the top and whose own large title never
          // resolves in this SwiftUI-in-modal context — the "gray artifact" that
          // clips the UI. Inline matches every sub-screen and shows "Settings"
          // cleanly with no large-title bar.
          .navigationBarTitleDisplayMode(.inline)
      }
    #endif
  }
}

// MARK: - SettingsView_Previews

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}
