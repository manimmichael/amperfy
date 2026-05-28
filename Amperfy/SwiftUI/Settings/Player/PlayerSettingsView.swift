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

// MARK: - PlayerSettingsView

struct PlayerSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  var body: some View {
    ZStack {
      SettingsList {
        // ReplayGain Settings
        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Enable ReplayGain",
              isOn: Binding(
                get: { settings.isReplayGainEnabled },
                set: { isEnabled in
                  settings.isReplayGainEnabled = isEnabled
                }
              )
            )
          },
          footer: "Automatically normalize track volume based on replay gain information for consistent loudness."
        )

        // General Settings
        SettingsSection {
          SettingsCheckBoxRow(
            title: "Auto cache played Songs",
            isOn: $settings.isPlayerAutoCachePlayedItems
          )
        }

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Song Playback Resume",
              isOn: $settings.isPlayerSongPlaybackResumeEnabled
            )
          },
          footer: "Keeps track of song progress so playback continues from the previously saved position."
        )

        SettingsSection(content: {
          SettingsCheckBoxRow(title: "Manual Playback", isOn: $settings.isPlaybackStartOnlyOnPlay)
        }, footer: "Enable to start playback only when the Play button is pressed.")

        // cassette polish Part 6: transcoding/bitrate rows (Cellular/WiFi
        // Format + Bitrate, Cache Format) are hidden — Cassette plays files
        // as-is. The underlying defaults are now `.raw` (see
        // SettingEnumerations), so the hidden settings mean no transcoding.
      }
    }
    .navigationTitle("Player")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      appDelegate.userStatistics.visited(.settingsPlayer)
    }
  }
}

// MARK: - PlayerSettingsView_Previews

struct PlayerSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    PlayerSettingsView().environmentObject(settings)
  }
}
