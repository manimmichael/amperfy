//
//  SecondaryText.swift
//  Amperfy
//
//  Created by David Klopp on 16.08.24.
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

struct SecondaryText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    // cassette Patch 015g: trailing metadata (version, build no.,
    // disk usage, etc.) reads in the mono catalog face.
    Text(text)
      .font(.cassetteMono(size: 12))
      .foregroundStyle(CassetteTheme.Colors.ink2)
      .help(text)
  }
}
