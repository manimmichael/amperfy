//
//  SettingsSection.swift
//  Amperfy
//
//  Created by David Klopp on 14.08.24.
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

struct SettingsSection<Content: View>: View {
  let footer: String?
  let header: String?
  let content: () -> Content

  init(
    @ViewBuilder content: @escaping () -> Content,
    footer: String? = nil,
    header: String? = nil
  ) {
    self.content = content
    self.footer = footer
    self.header = header
  }

  // cassette Patch 032: section header is sectionLabel (13pt bold display,
  // uppercased here); footer bumps 11pt -> 12pt regular mono (caption) for
  // the 12pt floor.
  private func headerText(_ value: String) -> some View {
    Text(value.uppercased())
      .font(.cassette(.sectionLabel))
      .tracking(0.6)
      .foregroundColor(CassetteTheme.Colors.ink2)
  }

  private func footerText(_ value: String) -> some View {
    Text(value)
      .font(.cassette(.caption))
      .foregroundColor(CassetteTheme.Colors.ink3)
  }

  var body: some View {
    if let footer = footer, let header = header {
      Section(
        content: content,
        header: { headerText(header) },
        footer: { footerText(footer) }
      )
    } else if let header = header {
      Section(content: content, header: { headerText(header) })
    } else if let footer = footer {
      Section(content: content, footer: { footerText(footer) })
    } else {
      Section(content: content)
    }
  }
}
