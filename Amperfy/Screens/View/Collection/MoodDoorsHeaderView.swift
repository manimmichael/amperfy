//
//  MoodDoorsHeaderView.swift
//  Amperfy
//
//  Cassette: the Home "Mood" shelf — a header-only HomeSection (zero
//  HomeItems; a mood door isn't a PlayableContainable, it's a static preset
//  that generates a mixtape on tap, so it deliberately does NOT flow through
//  the HomeItem/diffable-snapshot pipeline every other shelf uses — see
//  HomeSection.swift's .moodDoors case). This view hosts the SwiftUI tile
//  row directly as a collection-view supplementary header, using the same
//  addChild/addSubview/didMove(toParent:) containment already shipped for
//  SwiftUIContentView in LargeCurrentlyPlayingPlayerView.swift.

import AmperfyKit
import SwiftUI
import UIKit

final class MoodDoorsHeaderView: UICollectionReusableView {
  static let reuseID = "MoodDoorsHeaderView"

  private var hostingController: UIHostingController<MoodDoorRow>?

  /// Set by HomeVC when configuring this header: the view controller the hosted row is a
  /// child of.
  weak var parentViewController: UIViewController?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.cassette(.surfaceBase)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Re-hosts the SwiftUI row against the CURRENT parentViewController each
  /// time this reusable view is configured — reuse means the same instance
  /// can outlive the view controller that first hosted it (e.g. across a
  /// pull-to-refresh), so the hosting controller is torn down and rebuilt on
  /// every configure rather than only once in init.
  ///
  /// phone-taste: `mixes` are HomeManager's made-for-you playlists (Lately first). The row
  /// draws and plays exactly those, and never builds one itself; `onOpen` opens one's page.
  func configure(
    parentViewController: UIViewController,
    mixes: [HomeManager.MadeForYouMix],
    onOpen: @escaping (HomeManager.MadeForYouMix) -> ()
  ) {
    self.parentViewController = parentViewController

    hostingController?.willMove(toParent: nil)
    hostingController?.view.removeFromSuperview()
    hostingController?.removeFromParent()

    let row = MoodDoorRow(mixes: mixes, onOpen: onOpen)
    let hosting = UIHostingController(rootView: row)
    hostingController = hosting

    parentViewController.addChild(hosting)
    addSubview(hosting.view)
    hosting.view.backgroundColor = .clear
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    hosting.didMove(toParent: parentViewController)
  }
}
