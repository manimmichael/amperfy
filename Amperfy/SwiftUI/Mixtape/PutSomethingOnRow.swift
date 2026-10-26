//
//  PutSomethingOnRow.swift
//  Amperfy
//
//  Cassette: the Home "PUT something on" row (founder, 2026-10-26: "its own row under
//  Resume"). One tile per thing a person might be doing, each already showing its answer: the
//  person's own playlist (its picture, the song count) or a live station (its mark, LIVE, its
//  name). The whole tile plays at once, picture or disc: the row's one job is to put something
//  on, and a station has no page of songs to open. The row draws and plays the tiles HomeManager
//  keeps (updatePutSomethingOn) and never decides an answer itself; the cloud does
//  (/api/sync/put-something-on).
//
//  Like the made-for-you row it is SwiftUI hosted in a header-only Home section
//  (PutSomethingOnHeaderView below).
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - PutSomethingOnRow

struct PutSomethingOnRow: View {
  /// HomeManager's tiles, in the cloud's order. Empty: the row is not shown.
  let tiles: [HomeManager.PutSomethingOnTile]

  /// The mock's `.shelf` gap.
  private static let tileSpacing: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: CassetteHeading.bottomSpacing) {
      CassetteHeadingText(shout: "PUT", answer: "something on")
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.top, CassetteHeading.topSpacing)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Self.tileSpacing) {
          ForEach(tiles, id: \.key) { tile in
            PutSomethingOnTileView(tile: tile, play: { Self.play(tile) })
          }
        }
        .padding(.horizontal, AlbumCarousel.mockGutter)
      }
    }
    // The cover shelves' bottom inset (the next row's heading brings its own 28pt).
    .padding(.bottom, 2)
  }

  private static var app: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  /// Plays what the tile shows: the playlist, checked against the phone at the tap (by
  /// OneTapPlay's rule), or the station with the activity's other stations behind it, so Next
  /// tunes along them.
  static func play(_ tile: HomeManager.PutSomethingOnTile) {
    switch tile.answer {
    case let .playlist(songs, _):
      let playables = OneTapPlay.playables(songs)
      guard !playables.isEmpty else { return }
      app.player.play(context: PlayContext(name: tile.title, playables: playables))
    case let .station(radio, all, _):
      let index = all.firstIndex(where: { $0.id == radio.id }) ?? 0
      app.player.play(context: PlayContext(name: tile.title, index: index, playables: all.isEmpty ? [radio] : all))
    }
    Haptics.light.vibrate(isHapticsEnabled: app.storage.settings.user.isHapticsEnabled)
  }
}

// MARK: - PutSomethingOnTileView

/// One activity as an album tile: a 150pt square picture with the play disc at its
/// bottom-right (a station's also carries LIVE at its bottom-left), then the activity's name
/// and what it plays: the song count, or the station.
private struct PutSomethingOnTileView: View {
  static let side: CGFloat = MoodDoorTile.side

  let tile: HomeManager.PutSomethingOnTile
  let play: () -> ()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomTrailing) {
        Button(action: play) {
          art
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
            .contentShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.title), \(answerLine)")
        .accessibilityHint("Plays")

        if isStation {
          LiveMark()
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
        }

        CassettePlayDisc(action: play)
          .padding(8)
      }
      .frame(width: Self.side, height: Self.side)

      Button(action: play) {
        VStack(alignment: .leading, spacing: 2) {
          Text(tile.title)
            .font(Font.cassette(.rowTitle))
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(1)
          Text(answerLine)
            .font(Font.cassette(.cardSubtitle))
            .foregroundStyle(Color.cassette(.textSecondary))
            .lineLimit(1)
        }
        .padding(.top, 6)
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
    }
    .frame(width: Self.side, alignment: .leading)
  }

  private var isStation: Bool {
    if case .station = tile.answer { return true }
    return false
  }

  /// "30 songs", the station's name, or a live station's name and the show on now.
  private var answerLine: String {
    switch tile.answer {
    case let .playlist(songs, _): return "\(songs.count) songs"
    case let .station(_, _, info):
      guard let show = info.show, !show.isEmpty else { return info.name }
      return "\(info.name) · \(show)"
    }
  }

  @ViewBuilder
  private var art: some View {
    switch tile.answer {
    case let .playlist(_, variant):
      // Focus and Wind down are the made-for-you mood playlists and wear their drawn covers;
      // the others wear their colour and shape.
      MixCoverArt(
        address: variant.flatMap { MixCoverCache.address(key: tile.key, variant: $0) },
        key: tile.key,
        hexColor: tile.hexColor
      )
    case let .station(_, _, info):
      StationArt(info: info, side: Self.side)
    }
  }
}

// MARK: - LiveMark

/// LIVE on a station's picture, in the live colour (orange is for live state).
private struct LiveMark: View {
  var body: some View {
    Text("LIVE")
      .font(Font.cassetteMono(size: 10, weight: .medium))
      .tracking(1.2)
      .foregroundStyle(Color.cassette(.textOnFill))
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: CassetteRadius.small)
          .fill(Color.cassette(.accentProgress))
      )
      .accessibilityHidden(true)
  }
}

// MARK: - StationArt

/// A station's mark, or until (unless) it lands, its word picture: its colour running into the
/// dark with its name in our type, as on the Radio row.
private struct StationArt: View {
  let info: PutSomethingOnFeed.Station
  let side: CGFloat

  @State
  private var image: UIImage?
  @Environment(\.displayScale)
  private var displayScale

  init(info: PutSomethingOnFeed.Station, side: CGFloat) {
    self.info = info
    self.side = side
    _image = State(initialValue: info.image.flatMap { RadioArtLoader.shared.cachedImage(for: $0) })
  }

  var body: some View {
    Image(uiImage: image ?? wordArt)
      .resizable()
      .scaledToFill()
      .accessibilityHidden(true)
      .task(id: info.image) {
        guard image == nil, let address = info.image, !address.isEmpty else { return }
        if let loaded = await RadioArtLoader.shared.image(for: address) {
          withAnimation(.easeIn(duration: 0.3)) { image = loaded }
        }
      }
  }

  private var wordArt: UIImage {
    CarPlayStyle.phoneWordArt(
      word: info.name,
      color: UIColor(cassetteHexString: info.accent) ?? CassetteTheme.UIColors.bg3,
      side: side,
      scale: displayScale
    )
  }
}

// MARK: - PutSomethingOnHeaderView

/// Hosts the row as a collection-view supplementary header, the way MoodDoorsHeaderView hosts
/// the made-for-you row (a header-only Home section; see HomeSection.putSomethingOn).
final class PutSomethingOnHeaderView: UICollectionReusableView {
  static let reuseID = "PutSomethingOnHeaderView"

  private var hostingController: UIHostingController<PutSomethingOnRow>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.cassette(.surfaceBase)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Re-hosts the row against the current parent each time, as MoodDoorsHeaderView does: a
  /// reused header can outlive the view controller that first hosted it.
  func configure(parentViewController: UIViewController, tiles: [HomeManager.PutSomethingOnTile]) {
    hostingController?.willMove(toParent: nil)
    hostingController?.view.removeFromSuperview()
    hostingController?.removeFromParent()

    let hosting = UIHostingController(rootView: PutSomethingOnRow(tiles: tiles))
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
