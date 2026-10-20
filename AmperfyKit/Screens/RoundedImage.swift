//
//  RoundedImage.swift
//  AmperfyKit
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

import UIKit

// MARK: - CornerRadius

public enum CornerRadius {
  case verySmall
  case small
  case big

  public var asCGFloat: CGFloat {
    switch self {
    // Amperfy's names, resolved from `CassetteRadius` (Wave 2).
    case .verySmall:
      return CassetteRadius.artworkTile
    case .small:
      return CassetteRadius.artworkRow
    case .big:
      return CassetteRadius.large
    }
  }
}

// MARK: - RoundedImage

public class RoundedImage: UIImageView {
  public static let cornerRadius: CGFloat = CornerRadius.small.asCGFloat

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    configureStyle()
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    configureStyle()
  }

  func configureStyle() {
    layer.cornerRadius = Self.cornerRadius
    layer.masksToBounds = true
  }
}
