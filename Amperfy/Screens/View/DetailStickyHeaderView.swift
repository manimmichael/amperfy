//
//  DetailStickyHeaderView.swift
//  Amperfy
//
//  cassette Patch 064: compact title bar when detail hero scrolls off-screen.

import AmperfyKit
import UIKit

final class DetailStickyHeaderView: UIView {
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let bottomBorder = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = CassetteTheme.UIColors.bg2
    isUserInteractionEnabled = false
    alpha = 0

    titleLabel.font = UIFont.cassette(.sectionTitle)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    titleLabel.numberOfLines = 1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.font = UIFont.cassette(.metadata)
    subtitleLabel.textColor = CassetteTheme.UIColors.ink2
    subtitleLabel.numberOfLines = 1
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    bottomBorder.backgroundColor = CassetteTheme.UIColors.ink4
    bottomBorder.translatesAutoresizingMaskIntoConstraints = false

    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(bottomBorder)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),

      bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
      bottomBorder.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, subtitle: String?) {
    titleLabel.text = title
    if let subtitle, !subtitle.isEmpty {
      subtitleLabel.text = subtitle
      subtitleLabel.isHidden = false
    } else {
      subtitleLabel.text = nil
      subtitleLabel.isHidden = true
    }
  }
}
