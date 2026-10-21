//
//  CommonCollectionSectionHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 27.09.22.
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
import UIKit

class CommonCollectionSectionHeader: UICollectionReusableView {
  /// A letter header (phone-taste `.libSection` + `.letter`): 18 above the letter, its
  /// 22pt line, 10 below.
  static let frameHeight: CGFloat = 50.0
  /// The count line over the first letter (phone-taste `.libCount`): 14 above, a 13pt line.
  static let countBlockHeight: CGFloat = countTopSpacing + countLineHeight
  /// Under a count line with no letter below it (a flat grid): one row gap.
  static let countOnlyBottomSpacing: CGFloat = 14.0
  /// Both lines start where the tiles do.
  static let leadingInset: CGFloat = 20.0

  private static let titleTopSpacing: CGFloat = 18
  private static let titleLineHeight: CGFloat = 22
  private static let countTopSpacing: CGFloat = 14
  private static let countLineHeight: CGFloat = 13

  /// The header's height for what it shows. Zero when it shows nothing.
  static func height(showsCount: Bool, showsTitle: Bool) -> CGFloat {
    switch (showsCount, showsTitle) {
    case (true, true): return countBlockHeight + frameHeight
    case (true, false): return countBlockHeight + countOnlyBottomSpacing
    case (false, true): return frameHeight
    case (false, false): return 0
    }
  }

  /// The section letter: Barlow Condensed ExtraBold 22 (the mock's `.letter`).
  private static var titleFont: UIFont {
    UIFont.cassetteDisplay(size: titleLineHeight, weight: .extraBold)
  }

  /// Where a line's baseline sits when the mock sets it in a box of `lineHeight` starting
  /// `top` down (CSS line-height, so the type centres in the box as it does on the web).
  private static func baseline(top: CGFloat, lineHeight: CGFloat, font: UIFont) -> CGFloat {
    top + (lineHeight - font.lineHeight) / 2 + font.ascender
  }

  @IBOutlet
  weak var titleLabel: UILabel!

  /// The mono count line ("139 ALBUMS"), added in code above the letter.
  private let countLabel = UILabel()
  private var titleBaselineConstraint: NSLayoutConstraint?

  private var detailHeader: LibraryElementDetailTableHeaderView?

  override func awakeFromNib() {
    super.awakeFromNib()
    layOutLines()
  }

  /// The XIB pins the letter to the bottom of a fixed 30pt box, 8pt inside the margin. Pin
  /// both lines here instead, by baseline, 20 in from the leading edge.
  private func layOutLines() {
    guard let label = titleLabel else { return }
    let xibContainer = label.superview
    label.removeFromSuperview()
    if let xibContainer, xibContainer !== self {
      xibContainer.isHidden = true
    }
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 1
    label.accessibilityTraits = .header
    addSubview(label)

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.numberOfLines = 1
    countLabel.isHidden = true
    addSubview(countLabel)

    let titleBaseline = label.firstBaselineAnchor.constraint(
      equalTo: topAnchor,
      constant: Self.titleBaseline(belowCount: false)
    )
    titleBaselineConstraint = titleBaseline
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -Self.leadingInset
      ),
      titleBaseline,
      countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
      countLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -Self.leadingInset
      ),
      countLabel.firstBaselineAnchor.constraint(
        equalTo: topAnchor,
        constant: Self.baseline(
          top: Self.countTopSpacing,
          lineHeight: Self.countLineHeight,
          font: UIFont.cassette(.meta)
        )
      ),
    ])
  }

  private static func titleBaseline(belowCount: Bool) -> CGFloat {
    baseline(
      top: (belowCount ? countBlockHeight : 0) + titleTopSpacing,
      lineHeight: titleLineHeight,
      font: titleFont
    )
  }

  func display(title: String?, count: String? = nil) {
    // phone-taste: the letter in Barlow ExtraBold 22, ink2, in capitals (the mock's
    // `.letter`). The Rating / Year / Artist sorts set their titles in the same face.
    titleLabel.text = title?.uppercased()
    titleLabel.isHidden = (title == nil)
    titleLabel.font = Self.titleFont
    titleLabel.textColor = UIColor.cassette(.textSecondary)

    // The count line: DM Mono Medium 13, tracked, in capitals, ink2 (ink3 is under 4.5:1).
    if let count {
      countLabel.attributedText = NSAttributedString.cassette(
        count,
        .meta,
        color: .cassette(.textSecondary)
      )
      countLabel.accessibilityLabel = count
    } else {
      countLabel.attributedText = nil
      countLabel.accessibilityLabel = nil
    }
    countLabel.isHidden = (count == nil)
    titleBaselineConstraint?.constant = Self.titleBaseline(belowCount: count != nil)
  }

  func displayPlayHeader(configuration: PlayShuffleInfoConfiguration) {
    detailHeader = ViewCreator<LibraryElementDetailTableHeaderView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: bounds.size.width,
        height: LibraryElementDetailTableHeaderView.frameHeight
      ))
    detailHeader?.prepare(configuration: configuration)
    detailHeader?.refresh()
    if let detailHeader = detailHeader {
      addSubview(detailHeader)
    }
  }

  override func prepareForReuse() {
    detailHeader?.removeFromSuperview()
    detailHeader?.isHidden = true
    detailHeader = nil

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.detailHeader?.refresh()
      }
    )
  }
}
