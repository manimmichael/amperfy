//
//  CassetteIBStyle.swift
//  Amperfy
//
//  Cassette: Interface Builder files hold layout only (design-system audit 2026-10-20,
//  Wave 4). Every font and colour on a view loaded from a XIB or storyboard is applied
//  in code, through these helpers, from the class's one `applyCassetteStyle()`.
//
//  Why: IB stored Amperfy's system fonts and grey/white colours (82 fonts, 93 colours,
//  none of them Cassette) and code painted over them once. Anything that re-read the nib
//  (a size-class variation re-applied on a long-press, BUG-417) brought Amperfy back, and
//  every value code forgot shipped as stock iOS (BUG-427). The XIBs now carry no styling,
//  so there is nothing to revert to; `scripts/check-tokens.sh` counts any that comes back.
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

@MainActor
enum CassetteIBStyle {
  static func label(_ label: UILabel?, _ style: CassetteTextStyle, _ color: CassetteColorRole) {
    guard let label else { return }
    label.font = .cassette(style)
    label.textColor = .cassette(color)
    label.adjustsFontForContentSizeCategory = false
  }

  static func textView(
    _ textView: UITextView?,
    _ style: CassetteTextStyle,
    _ color: CassetteColorRole
  ) {
    guard let textView else { return }
    textView.font = .cassette(style)
    textView.textColor = .cassette(color)
    textView.backgroundColor = .clear
  }

  /// An icon or text button that is not filled: tint and title in one role.
  static func plainButton(_ button: UIButton?, _ color: CassetteColorRole = .textPrimary) {
    guard let button else { return }
    button.tintColor = .cassette(color)
    button.setTitleColor(.cassette(color), for: .normal)
    button.backgroundColor = .clear
  }

  /// The one filled call to action on a screen: ink capsule, dark label.
  static func filledButton(_ button: UIButton?, title: String? = nil) {
    guard let button else { return }
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = .cassette(.fillSelected)
    config.baseForegroundColor = .cassette(.textOnFill)
    config.cornerStyle = .capsule
    let text = title ?? button.configuration?.title ?? button.title(for: .normal) ?? ""
    var attributes = AttributeContainer()
    attributes.font = UIFont.cassette(.rowTitle)
    config.attributedTitle = AttributedString(text, attributes: attributes)
    button.configuration = config
    button.backgroundColor = .clear
  }

  static func progress(_ bar: UIProgressView?) {
    guard let bar else { return }
    bar.progressTintColor = .cassette(.accentProgress)
    bar.trackTintColor = .cassette(.hairline)
  }

  static func spinner(_ spinner: UIActivityIndicatorView?) {
    spinner?.color = .cassette(.textSecondary)
  }

  /// A full screen: the page surface behind it.
  static func screen(_ view: UIView?) {
    view?.backgroundColor = .cassette(.surfaceBase)
  }

  /// A sheet: the raised surface (replaces Amperfy's system blur, which reads grey).
  static func sheet(_ view: UIView?) {
    view?.backgroundColor = .cassette(.surfaceRaised)
  }
}

extension UIView {
  /// Every descendant, depth first. For styling IB views that have no outlet.
  var cassetteAllSubviews: [UIView] {
    subviews.flatMap { [$0] + $0.cassetteAllSubviews }
  }

  /// The labels a screen draws itself: not the ones inside a button or other control.
  var cassetteStandaloneLabels: [UILabel] {
    subviews.flatMap { view -> [UILabel] in
      if view is UIControl { return [] }
      return ((view as? UILabel).map { [$0] } ?? []) + view.cassetteStandaloneLabels
    }
  }
}
