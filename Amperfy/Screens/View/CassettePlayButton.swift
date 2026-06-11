//
//  CassettePlayButton.swift
//  Amperfy
//
//  Cassette fork: skeuomorphic prominent Play button for detail headers.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import AmperfyKit
import UIKit

/// cassette polish Part 4: a skeuomorphic, prominent circular Play button used
/// in the Album / Artist / Playlist detail headers. The recessed-then-raised
/// disc treatment is encapsulated here so the rendering lives in one reusable
/// place rather than being scattered across detail view controllers.
///
/// Visual spec: 68pt ink-filled circle, `play.fill` glyph in `bg`, a 1pt top
/// rim highlight (ink2 a0.5, ~80° arc), a bottom inner shadow (ink2 a0.3), and
/// a soft drop shadow (ink a0.2, y+2). Touch-down compresses to scale 0.95,
/// fades the rim and softens the drop shadow over 80ms; release restores over
/// 120ms. A medium impact haptic fires on touch-down.
@MainActor
final class CassettePlayButton: UIControl {
  static let diameter: CGFloat = 68.0

  /// cassette Polish 2 (D1): the diameter is now per-instance so the detail
  /// action bar can use a smaller 56pt disc while the default stays 68pt.
  private let configuredDiameter: CGFloat

  private let glyphView = UIImageView()
  private let rimLayer = CAShapeLayer()
  private let innerShadowLayer = CAShapeLayer()
  private let innerShadowMask = CAShapeLayer()

  /// Invoked on touch-up-inside. Wire this to the existing play action.
  var onTap: (() -> ())?

  init(diameter: CGFloat = CassettePlayButton.diameter) {
    self.configuredDiameter = diameter
    super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
    setup()
  }

  override convenience init(frame: CGRect) {
    self.init(diameter: CassettePlayButton.diameter)
  }

  required init?(coder: NSCoder) {
    self.configuredDiameter = CassettePlayButton.diameter
    super.init(coder: coder)
    setup()
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: configuredDiameter, height: configuredDiameter)
  }

  private func setup() {
    backgroundColor = CassetteTheme.UIColors.ink
    layer.cornerRadius = configuredDiameter / 2
    layer.masksToBounds = false

    // Soft drop shadow beneath the disc — the "raised" cue.
    layer.shadowColor = CassetteTheme.UIColors.ink.cgColor
    layer.shadowOpacity = 0.2
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 2)

    // Top rim highlight (drawn in layoutSubviews once bounds are known).
    rimLayer.fillColor = UIColor.clear.cgColor
    rimLayer.strokeColor = CassetteTheme.UIColors.ink2.withAlphaComponent(0.5).cgColor
    rimLayer.lineWidth = 1
    rimLayer.lineCap = .round
    layer.addSublayer(rimLayer)

    // Bottom inner shadow — the "recessed" cue. Classic inner-shadow trick:
    // an even-odd path (outer rect minus the circle) casts its shadow inward,
    // masked to the circle so only the inside edge darkens.
    innerShadowLayer.fillRule = .evenOdd
    innerShadowLayer.fillColor = CassetteTheme.UIColors.ink2.cgColor
    innerShadowLayer.shadowColor = CassetteTheme.UIColors.ink2.withAlphaComponent(0.3).cgColor
    innerShadowLayer.shadowOpacity = 1
    innerShadowLayer.shadowRadius = 2
    innerShadowLayer.shadowOffset = CGSize(width: 0, height: -1.5)
    innerShadowLayer.mask = innerShadowMask
    layer.addSublayer(innerShadowLayer)

    glyphView.image = UIImage(
      systemName: "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(
        pointSize: (configuredDiameter * 0.35).rounded(),
        weight: .medium
      )
    )
    glyphView.tintColor = CassetteTheme.UIColors.bg
    glyphView.contentMode = .center
    glyphView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glyphView)
    NSLayoutConstraint.activate([
      glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
      // play.fill reads optically centered when nudged ~1pt to the right.
      glyphView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 1),
    ])

    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityLabel = "Play"

    addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
    addTarget(self, action: #selector(handleTouchUpInside), for: .touchUpInside)
    addTarget(
      self,
      action: #selector(handleTouchRelease),
      for: [.touchUpOutside, .touchCancel]
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath

    let circlePath = UIBezierPath(ovalIn: bounds)

    // Top rim arc, ~80° centered on 12 o'clock (-90°).
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius = bounds.width / 2 - 0.5
    let halfArc = (80.0 / 2.0) * .pi / 180.0
    let top = -CGFloat.pi / 2
    rimLayer.frame = bounds
    rimLayer.path = UIBezierPath(
      arcCenter: center,
      radius: radius,
      startAngle: top - halfArc,
      endAngle: top + halfArc,
      clockwise: true
    ).cgPath

    // Inner shadow casting path + circle mask.
    let outer = UIBezierPath(rect: bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
    outer.append(circlePath)
    outer.usesEvenOddFillRule = true
    innerShadowLayer.frame = bounds
    innerShadowLayer.path = outer.cgPath
    innerShadowLayer.shadowPath = circlePath.cgPath
    innerShadowMask.path = circlePath.cgPath
  }

  @objc
  private func handleTouchDown() {
    Haptics.medium.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    setPressed(true)
  }

  @objc
  private func handleTouchUpInside() {
    setPressed(false)
    onTap?()
  }

  @objc
  private func handleTouchRelease() {
    setPressed(false)
  }

  private func setPressed(_ pressed: Bool) {
    let duration = pressed ? 0.08 : 0.12
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.transform = pressed ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
    }
    CATransaction.begin()
    CATransaction.setAnimationDuration(duration)
    // Rim base alpha is 0.5; opacity 0.4 -> effective ~0.2 when pressed.
    rimLayer.opacity = pressed ? 0.4 : 1.0
    layer.shadowRadius = pressed ? 2 : 4
    layer.shadowOpacity = pressed ? 0.1 : 0.2
    CATransaction.commit()
  }
}
