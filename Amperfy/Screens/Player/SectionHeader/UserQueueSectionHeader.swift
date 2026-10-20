//
//  UserQueueSectionHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 22.11.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import UIKit

class UserQueueSectionHeader: UIView {
  @IBOutlet
  weak var nameLabel: MarqueeLabel!
  @IBOutlet
  weak var rightButton: UIButton!

  static let frameHeight: CGFloat = 28.0 + margin.top + margin.bottom
  static let margin = UIEdgeInsets(
    top: 8,
    left: UIView.defaultMarginX,
    bottom: 8,
    right: UIView.defaultMarginX
  )

  private var buttonPressAction: (() -> ())?

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  func hide() {
    nameLabel.text = ""
    nameLabel.isHidden = true
    rightButton.isHidden = true
    rightButton.isEnabled = false
  }

  func display(name: String, buttonPressAction: @escaping (() -> ())) {
    nameLabel.text = name.uppercased()
    nameLabel.isHidden = false
    nameLabel.applyAmperfyStyle()
    applyCassetteType()
    rightButton.isHidden = false
    rightButton.isEnabled = true
    self.buttonPressAction = buttonPressAction
  }

  /// cassette (BUG-418): section-label type for the queue name, and the XIB's
  /// gray system "Clear" button becomes a bare ink2 label in the same face.
  private func applyCassetteType() {
    nameLabel.font = UIFont.cassette(.sectionLabel)
    nameLabel.textColor = CassetteTheme.UIColors.ink2
    var clear = UIButton.Configuration.cassetteBare()
    var attributes = AttributeContainer()
    attributes.font = UIFont.cassette(.sectionLabel)
    attributes.foregroundColor = CassetteTheme.UIColors.ink2
    clear.attributedTitle = AttributedString("CLEAR", attributes: attributes)
    clear.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 0)
    rightButton.configuration = clear
    rightButton.tintColor = CassetteTheme.UIColors.ink2
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if !nameLabel.isHidden { applyCassetteType() }
  }

  @IBAction
  func rightButtonPressed(_ sender: Any) {
    if let buttonAction = buttonPressAction {
      buttonAction()
    }
  }
}
