//
//  ResumeCardCell.swift
//  Amperfy
//
//  cassette redesign (Surface 4): full-width "Resume" card that leads the
//  Home screen. The container copies the footer's exact Liquid Glass usage
//  (UIGlassEffect(.regular) in a UIVisualEffectView — see
//  MiniPlayerView.glassContainer); the play affordance is the cream brand
//  disc shared with the detail-header CTA. Sourced from the lastPlayedDate
//  FRCs via HomeManager (live queue first, then most recently played).
//

import AmperfyKit
import UIKit

final class ResumeCardCell: BasicCollectionCell {
  static let cardHeight: CGFloat = artworkSide + 2 * CassetteTheme.Spacing.md
  private static let artworkSide: CGFloat = 72.0
  private static let playDiameter: CGFloat = 44.0

  var onPlayTapped: (() -> ())?

  // Footer reference pattern: UIGlassEffect(.regular), non-interactive,
  // hosted in a UIVisualEffectView. Content lives in `contentView` of the
  // effect view so it renders above the glass.
  private let glassContainer: UIVisualEffectView = {
    let container = UIVisualEffectView()
    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = false
    container.effect = glassEffect
    container.cornerConfiguration = .corners(radius: .fixed(CassetteTheme.Radius.lg))
    container.translatesAutoresizingMaskIntoConstraints = false
    return container
  }()

  // cassette Patch 104: the broken artwork crop came from
  // `EntityImageView(frame: .zero)` — the view loads its nib content with
  // autoresizing masks scaled from the init frame, so a zero frame laid the
  // inner image out as garbage. Seed it with the real artwork square (the
  // constraints below keep it at that size).
  private let artworkView: EntityImageView = {
    let view = EntityImageView(
      frame: CGRect(
        x: 0,
        y: 0,
        width: ResumeCardCell.artworkSide,
        height: ResumeCardCell.artworkSide
      )
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let eyebrowLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.caption)
    label.textColor = CassetteTheme.UIColors.ink2
    label.text = "RESUME"
    return label
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.rowTitle)
    label.textColor = CassetteTheme.UIColors.ink
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let subtitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.metadata)
    label.textColor = CassetteTheme.UIColors.ink2
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  // Cream brand disc — same native CTA family as the detail header.
  private lazy var playButton: UIButton = {
    let button = LibraryElementDetailTableHeaderView.makeDetailPlayCTA(
      diameter: Self.playDiameter
    )
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
  }

  private func setupSubviews() {
    contentView.backgroundColor = .clear
    contentView.addSubview(glassContainer)

    let glassContent = glassContainer.contentView
    glassContent.addSubview(artworkView)
    glassContent.addSubview(eyebrowLabel)
    glassContent.addSubview(titleLabel)
    glassContent.addSubview(subtitleLabel)
    glassContent.addSubview(playButton)

    let pad = CassetteTheme.Spacing.md
    NSLayoutConstraint.activate([
      glassContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      glassContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      glassContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      glassContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      artworkView.leadingAnchor.constraint(equalTo: glassContent.leadingAnchor, constant: pad),
      artworkView.centerYAnchor.constraint(equalTo: glassContent.centerYAnchor),
      artworkView.widthAnchor.constraint(equalToConstant: Self.artworkSide),
      artworkView.heightAnchor.constraint(equalToConstant: Self.artworkSide),

      playButton.trailingAnchor.constraint(equalTo: glassContent.trailingAnchor, constant: -pad),
      playButton.centerYAnchor.constraint(equalTo: glassContent.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: Self.playDiameter),
      playButton.heightAnchor.constraint(equalToConstant: Self.playDiameter),

      eyebrowLabel.leadingAnchor.constraint(
        equalTo: artworkView.trailingAnchor,
        constant: pad
      ),
      eyebrowLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor,
        constant: -pad
      ),
      eyebrowLabel.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2),

      titleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor,
        constant: -pad
      ),
      titleLabel.centerYAnchor.constraint(equalTo: glassContent.centerYAnchor),

      subtitleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor,
        constant: -pad
      ),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
    ])
  }

  func display(container: PlayableContainable) {
    titleLabel.text = container.name
    subtitleLabel.text = container.subtitle
    subtitleLabel.isHidden = container.subtitle == nil
    artworkView.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container,
      cornerRadius: .small
    )
    // Same content-level hairline highlight as the album cards.
    artworkView.layer.borderWidth = 1.0 / max(traitCollection.displayScale, 1.0)
    artworkView.layer.borderColor = CassetteTheme.UIColors.ink
      .withAlphaComponent(0.08).cgColor
    accessibilityLabel = "Resume \(container.name)"
  }
}
