//
//  DetailStickyHeaderView.swift
//  Amperfy
//
//  cassette Patch 064: compact title bar when detail hero scrolls off-screen.
//  cassette Polish 2 (D3): repurposed from a separate 56pt band below the safe
//  area into the navigation bar's titleView. At rest it is transparent (the nav
//  bar shows only the back button); as the on-page hero scrolls under the nav
//  bar the title fades in. Title only — no subtitle, matching iOS detail pages.

import AmperfyKit
import UIKit

final class DetailStickyHeaderView: UIView {
  private let titleLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    alpha = 0

    titleLabel.font = UIFont.cassetteDisplay(size: 18, weight: .semibold)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    titleLabel.numberOfLines = 1
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(titleLabel)
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The nav bar sizes a titleView from its intrinsic content size.
  override var intrinsicContentSize: CGSize { titleLabel.intrinsicContentSize }

  /// `subtitle` is ignored — the nav title shows the entity name only.
  func configure(title: String, subtitle: String?) {
    titleLabel.text = title
    invalidateIntrinsicContentSize()
  }
}
