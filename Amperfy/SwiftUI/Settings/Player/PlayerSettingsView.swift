//
//  PlayerSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 15.09.22.
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

// MARK: - PlaybackSettingsView

// cassette §G/§E: this is the "Playback" screen (file name kept as
// PlayerSettingsView.swift to avoid .pbxproj churn — rename deferred). It hosts
// the Equalizer entry (tucked here rather than as a top-level peer) plus the few
// playback prefs a normal listener would plausibly change. ReplayGain, Manual
// Playback, and Song Playback Resume were culled (§B/§D).
struct PlaybackSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection {
          NavigationLink(destination: EqualizerSettingsView()) {
            Text("Equalizer")
          }
        }

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Keep songs you stream",
              isOn: $settings.isPlayerAutoCachePlayedItems
            )
          },
          footer: "Save a copy on this device of anything you stream in Server Mode, so it's there next time without using data."
        )

        // cassette §2 (decision answer): the Mac-only "Mini Player Always on
        // Top" control was collateral when the Display screen was removed.
        // Mac is shipping, so resurface it here — macCatalyst only.
        #if targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Mini Player Always on Top",
                isOn: $settings.isMiniPlayerAlwaysOnTop
              )
            },
            footer: "Keep the mini player window floating above all other windows."
          )
        #endif
      }
    }
    .navigationTitle("Playback")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      appDelegate.userStatistics.visited(.settingsPlayer)
    }
  }
}

// MARK: - PlaybackSettingsView_Previews

struct PlaybackSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    PlaybackSettingsView().environmentObject(settings)
  }
}
