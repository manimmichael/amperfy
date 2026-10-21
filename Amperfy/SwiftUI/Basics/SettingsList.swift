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
  /// The gap between groups; nil keeps the system's. Set here rather than inherited, so the
  /// Settings root's tighter gap never reaches the screens pushed from it.
  let sectionSpacing: CGFloat?
  let content: () -> Content

  init(sectionSpacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.sectionSpacing = sectionSpacing
    self.content = content
  }

  var body: some View {
    // cassette Patch 050 (Phase E): drop the orange tint from settings
    // lists. Toggles, chevrons, and section accents now use ink. Settings
    // should read as neutral chrome, not a brand showcase.
    // Phone-taste: the sheet is bg4 with bg3 groups and quiet hairlines, and the bar keeps
    // the page's colour on every screen built on this list, so a push never flashes.
    List {
      content()
        .listRowBackground(Color.cassette(.surfaceElevated))
        .listRowSeparatorTint(Color.cassette(.textPrimary).opacity(0.07))
    }
    .listSectionSpacing(sectionSpacing.map { ListSectionSpacing.custom($0) } ?? .default)
    .scrollContentBackground(.hidden)
    .background(Color.cassette(.surfaceSunken))
    .toolbarBackground(Color.cassette(.surfaceSunken), for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .tint(Color.cassette(.fillSelected))
    .foregroundColor(Color.cassette(.textPrimary))
  }
}
