//
//  SearchStartView.swift
//  Amperfy
//
//  Cassette: what Search shows before anyone types (UX review 2026-10-20, item 5).
//  A row of quiet starting points instead of an empty "No search history" page:
//  shuffle what is on the phone, or jump to a way of browsing it.
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
final class SearchStartView: UIView {
  struct Start {
    let title: String
    let icon: CassetteIcon
    let action: () -> ()
  }

  private static let inset: CGFloat = 16
  private static let chipHeight: CGFloat = 36

  private let scrollView = UIScrollView()
  private let stack = UIStackView()

  init(starts: [Start]) {
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.chipHeight + 24))
    backgroundColor = .clear

    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    stack.axis = .horizontal
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      scrollView.heightAnchor.constraint(equalToConstant: Self.chipHeight),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    for start in starts {
      stack.addArrangedSubview(Self.chip(for: start))
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func chip(for start: Start) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.cornerStyle = .capsule
    config.image = start.icon.uiImage(size: .row)
    config.imagePadding = 6
    config.baseForegroundColor = .cassette(.textPrimary)
    config.background.backgroundColor = .cassette(.surfaceRaised)
    config.background.strokeColor = .cassette(.hairline)
    config.background.strokeWidth = 1
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
    var attributes = AttributeContainer()
    attributes.font = UIFont.cassette(.miniTitle)
    config.attributedTitle = AttributedString(start.title, attributes: attributes)
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in start.action() })
    button.heightAnchor.constraint(equalToConstant: chipHeight).isActive = true
    return button
  }
}
