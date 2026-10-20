//
//  CassetteRailView.swift
//  Amperfy
//
//  Created for Cassette on 20.10.26 (BUG-423).
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

// MARK: - CassetteRailView

/// cassette (rail, BUG-423): the phone's bottom rail is ours.
///
/// The mini player pill above a tab capsule and a search circle: three Liquid
/// Glass shapes laid out where the stock iOS 26 bar put them (measured on the
/// 26.4 simulator: 21pt side margins, a 62pt capsule and circle 8pt apart,
/// the 48pt pill 8pt above, the capsule's bottom edge 13pt below the safe-area
/// edge, the selected item's lens 127x48). `TabBarVC` keeps UIKit's
/// UITabBarController for the tabs and their view controllers, hides its bar,
/// and slides this view with the finger instead.
///
/// Why: the stock bar's minimize is a 0.47s crossfade of a snapshot, it only
/// expands at the top of a list, it toggles itself at the end of one, and the
/// minimized bar gives the accessory no glass. Six commits of behaviour rules
/// on top of it never felt like Reddit's bar, because Reddit's bar is not
/// UITabBarController's. Now neither is ours.
@MainActor
final class CassetteRailView: UIView {
  struct Item {
    let title: String
    let image: UIImage
  }

  // MARK: Geometry of the stock bar (iPhone 17, iOS 26.4)

  static let sideInset: CGFloat = 21
  static let barHeight: CGFloat = 62
  static let pillHeight: CGFloat = 48
  static let gap: CGFloat = 8
  /// The stock bar's bottom edge hangs this far below the safe-area edge, over
  /// the home indicator's inset.
  static let bottomOverlap: CGFloat = 13
  /// Air between the last row of a list and the pill.
  static let contentClearance: CGFloat = 8
  static let iconSize: CGFloat = 24
  static let highlightHeight: CGFloat = 48
  /// The selected item's lens is this much narrower than the item.
  static let highlightInset: CGFloat = 13
  /// The items sit this far inside the capsule's ends.
  static let itemsInset: CGFloat = 5

  /// What a list's content must clear, above the home indicator's inset: the
  /// pill, the capsule under it, and a little air. UIKit did this for the
  /// accessory; `TabBarVC` adds it to its safe area now.
  static let contentInset: CGFloat = pillHeight + gap + barHeight - bottomOverlap +
    contentClearance

  // MARK: Callbacks

  var onSelectItem: ((Int) -> ())?
  var onSearch: (() -> ())?

  /// The window's own bottom inset (the home indicator). The capsule hangs
  /// `bottomOverlap` into it, as the stock bar does.
  var homeIndicatorInset: CGFloat = 0 {
    didSet {
      bottomPadding?.constant = -max(homeIndicatorInset - Self.bottomOverlap, Self.gap)
    }
  }

  private(set) var selectedIndex: Int?

  // MARK: Views

  private let bar: UIVisualEffectView
  private let searchCircle: UIVisualEffectView
  private let highlight: UIView
  private let searchControl: RailSearchControl
  private let items: [RailItemControl]
  private var highlightCenter: NSLayoutConstraint?
  private var highlightWidth: NSLayoutConstraint?
  private var bottomPadding: NSLayoutConstraint?
  private var pill: UIView?

  init(items: [Item]) {
    bar = Self.makeGlass()
    searchCircle = Self.makeGlass()
    highlight = UIView()
    searchControl = RailSearchControl()
    self.items = items.map { RailItemControl(item: $0) }
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    highlight.backgroundColor = CassetteTheme.UIColors.ink.withAlphaComponent(0.14)
    highlight.cornerConfiguration = .capsule()
    highlight.isUserInteractionEnabled = false
    highlight.translatesAutoresizingMaskIntoConstraints = false
    highlight.alpha = 0

    addSubview(bar)
    addSubview(searchCircle)
    bar.contentView.addSubview(highlight)

    let stack = UIStackView(arrangedSubviews: self.items)
    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(stack)
    for (index, item) in self.items.enumerated() {
      item.tag = index
      item.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
    }

    searchControl.translatesAutoresizingMaskIntoConstraints = false
    searchControl.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
    searchCircle.contentView.addSubview(searchControl)

    let bottomPadding = bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.gap)
    self.bottomPadding = bottomPadding

    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: topAnchor, constant: Self.pillHeight + Self.gap),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
      bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
      bar.trailingAnchor.constraint(equalTo: searchCircle.leadingAnchor, constant: -Self.gap),
      bottomPadding,

      searchCircle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
      searchCircle.widthAnchor.constraint(equalToConstant: Self.barHeight),
      searchCircle.heightAnchor.constraint(equalToConstant: Self.barHeight),
      searchCircle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

      stack.leadingAnchor.constraint(
        equalTo: bar.contentView.leadingAnchor,
        constant: Self.itemsInset
      ),
      stack.trailingAnchor.constraint(
        equalTo: bar.contentView.trailingAnchor,
        constant: -Self.itemsInset
      ),
      stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),

      highlight.heightAnchor.constraint(equalToConstant: Self.highlightHeight),
      highlight.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),

      searchControl.leadingAnchor.constraint(equalTo: searchCircle.contentView.leadingAnchor),
      searchControl.trailingAnchor.constraint(equalTo: searchCircle.contentView.trailingAnchor),
      searchControl.topAnchor.constraint(equalTo: searchCircle.contentView.topAnchor),
      searchControl.bottomAnchor.constraint(equalTo: searchCircle.contentView.bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func makeGlass() -> UIVisualEffectView {
    let view = UIVisualEffectView()
    let glass = UIGlassEffect(style: .regular)
    glass.isInteractive = false
    view.effect = glass
    view.cornerConfiguration = .capsule()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  // MARK: The pill

  /// The mini player's glass capsule, as it is: same view, same glass, same
  /// content as in the accessory slot it used to ride in.
  func install(pill: UIView) {
    self.pill?.removeFromSuperview()
    self.pill = pill
    pill.translatesAutoresizingMaskIntoConstraints = false
    pill.cornerConfiguration = .capsule()
    addSubview(pill)
    NSLayoutConstraint.activate([
      pill.topAnchor.constraint(equalTo: topAnchor),
      pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
      pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
      pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
    ])
  }

  // MARK: Selection

  /// `nil` is the search tab: no item lit, the lens fades out.
  func setSelectedItem(_ index: Int?, animated: Bool) {
    selectedIndex = index
    for (i, item) in items.enumerated() {
      item.apply(selected: i == index)
    }
    if let index, items.indices.contains(index) {
      let item = items[index]
      highlightCenter?.isActive = false
      highlightWidth?.isActive = false
      highlightCenter = highlight.centerXAnchor.constraint(equalTo: item.centerXAnchor)
      highlightWidth = highlight.widthAnchor.constraint(
        equalTo: item.widthAnchor,
        constant: -Self.highlightInset
      )
      highlightCenter?.isActive = true
      highlightWidth?.isActive = true
    }
    let lensAlpha: CGFloat = index == nil ? 0 : 1
    let changes = {
      self.highlight.alpha = lensAlpha
      self.bar.contentView.layoutIfNeeded()
    }
    guard animated, highlightCenter != nil else {
      changes()
      return
    }
    UIView.animate(
      withDuration: 0.35,
      delay: 0,
      usingSpringWithDamping: 0.85,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: changes
    )
  }

  @objc
  private func itemTapped(_ sender: UIControl) {
    onSelectItem?(sender.tag)
  }

  @objc
  private func searchTapped() {
    onSearch?()
  }

  // MARK: Hit testing

  /// Only the three shapes take touches; the content scrolls under the rest.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    for shape in [pill, bar, searchCircle].compactMap({ $0 }) where shape.frame.contains(point) {
      return true
    }
    return false
  }
}

// MARK: - RailItemControl

/// One tab: a 24pt Lucide glyph over a 10pt Barlow label, ink when selected,
/// ink2 otherwise (the theme's quiet tier; ink3 is too dim on glass).
private final class RailItemControl: UIControl {
  private let imageView = UIImageView()
  private let label = UILabel()

  init(item: CassetteRailView.Item) {
    super.init(frame: .zero)
    imageView.image = item.image.withRenderingMode(.alwaysTemplate)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    label.text = item.title
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [imageView, label])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 3
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: CassetteRailView.iconSize),
      imageView.heightAnchor.constraint(equalToConstant: CassetteRailView.iconSize),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityLabel = item.title
    apply(selected: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(selected: Bool) {
    let color = selected ? CassetteTheme.UIColors.ink : CassetteTheme.UIColors.ink2
    imageView.tintColor = color
    label.textColor = color
    label.font = UIFont.cassetteDisplay(size: 10, weight: selected ? .bold : .semibold)
    accessibilityTraits = selected ? [.button, .selected] : [.button]
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.6 : 1 }
  }
}

// MARK: - RailSearchControl

/// The search circle's glyph.
private final class RailSearchControl: UIControl {
  private let imageView = UIImageView()

  init() {
    super.init(frame: .zero)
    imageView.image = TabNavigatorItem.search.outlineIcon.withRenderingMode(.alwaysTemplate)
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = CassetteTheme.UIColors.ink
    imageView.isUserInteractionEnabled = false
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: CassetteRailView.iconSize),
      imageView.heightAnchor.constraint(equalToConstant: CassetteRailView.iconSize),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityLabel = TabNavigatorItem.search.title
    accessibilityTraits = [.button]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.6 : 1 }
  }
}
