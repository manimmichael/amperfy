//
//  SettingsList.swift
//  Amperfy
//
//  Created by David Klopp on 07.09.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import SwiftUI

struct SettingsList<Content: View>: View {
  let content: () -> Content

  init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  var body: some View {
    // cassette Patch 015g: every settings list adopts the warm Cassette
    // palette. .scrollContentBackground(.hidden) lets the bg token
    // show through the system Form chrome on iOS 16+. Tint pins
    // toggles, navigation chevrons, and section accent colour to
    // Cassette orange.
    List {
      content()
        .listRowBackground(CassetteTheme.Colors.bg2)
    }
    .scrollContentBackground(.hidden)
    .background(CassetteTheme.Colors.bg)
    .tint(CassetteTheme.Colors.orange)
    .foregroundColor(CassetteTheme.Colors.ink)
  }
}
