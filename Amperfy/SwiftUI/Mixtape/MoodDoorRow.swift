//
//  MoodDoorRow.swift
//  Amperfy
//
//  Cassette: the Home "PLAYLISTS made for you" row (was the "Mood" shelf).
//
//  cassette 2026-10-20: the first tile is "Lately", a mix of songs on this phone that
//  match the mood of what the person has been playing (ListeningShelves).
//
//  phone-taste (approved phone mock, 2026-10-20): the row reads like every other Home row
//  (the shout, the shelf's 20pt gutter and 12pt gap, 150pt square tiles).
//
//  Founder, 2026-10-21: the row says what it is (PLAYLISTS *made for you*), and each tile
//  gets the album treatment: the picture, the one-tap play disc, and the name and song count
//  under it rather than on it. A tap on the picture opens the playlist's page (what's
//  inside); the disc plays it. Beside Lately sit the other made-for-you playlists (this
//  part of the day, Been a While, the mood mixes), all drawn on the phone by HomeManager.
//  The server's mood doors no longer show here: the mood mixes replace them on the phone.
//  The row never builds a mix itself; it draws and plays the ones HomeManager keeps,
//  re-checked against the phone at the tap.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - MoodDoorRow

struct MoodDoorRow: View {
  /// HomeManager's made-for-you playlists, in row order. Empty: the row is not shown.
  let mixes: [HomeManager.MadeForYouMix]
  /// Opens a playlist's page.
  let onOpen: (HomeManager.MadeForYouMix) -> ()

  /// The mock's `.shelf` gap.
  private static let tileSpacing: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: CassetteHeading.bottomSpacing) {
      // The same two-voice heading, gutter and air as the UIKit rows around it.
      CassetteHeadingText(shout: "PLAYLISTS", answer: "made for you")
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.top, CassetteHeading.topSpacing)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Self.tileSpacing) {
          ForEach(mixes, id: \.id) { mix in
            MadeForYouTile(
              mix: mix,
              coverPaths: Self.coverPaths(of: mix),
              open: { onOpen(mix) },
              play: { Self.play(mix) }
            )
          }
        }
        .padding(.horizontal, AlbumCarousel.mockGutter)
      }
    }
    // The cover shelves' bottom inset (the next row's heading brings its own 28pt).
    .padding(.bottom, 2)
  }

  /// The app delegate, for these static helpers (`appDelegate` is an instance property).
  private static var app: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  /// The playlist's lead albums' covers that are on disk, in mix order.
  static func coverPaths(of mix: HomeManager.MadeForYouMix) -> [String] {
    let settings = app.storage.settings.accounts
    var seen = Set<String>()
    return mix.leadAlbums.compactMap { album -> String? in
      let preference = settings.getSetting(album.account?.info).read.artworkDisplayPreference
      guard let path = album.imagePath(setting: preference),
            FileManager.default.fileExists(atPath: path),
            seen.insert(path).inserted
      else { return nil }
      return path
    }
  }

  /// Plays the playlist the tile shows, checked against the phone at the tap (HomeManager
  /// keeps it between recomputes, and music can leave the phone in between), by
  /// OneTapPlay's rule.
  static func play(_ mix: HomeManager.MadeForYouMix) {
    let songs = OneTapPlay.playables(mix.songs)
    guard !songs.isEmpty else { return }
    app.player.play(context: PlayContext(name: mix.title, playables: songs))
    Haptics.light.vibrate(isHapticsEnabled: app.storage.settings.user.isHapticsEnabled)
  }
}

// MARK: - MadeForYouTile

/// One made-for-you playlist, as an album tile: a 150pt square picture with the one-tap
/// play disc at its bottom-right, then the name and the song count. The picture is four of
/// its records (Lately, the time of day, Been a While) or the mood's own art (a mood mix).
/// A tap on the picture opens the playlist; the disc plays it. The disc is a sibling of the
/// picture's button, never inside it (in SwiftUI the outer button's tap would win).
struct MadeForYouTile: View {
  static let side: CGFloat = MoodDoorTile.side

  let mix: HomeManager.MadeForYouMix
  let coverPaths: [String]
  let open: () -> ()
  let play: () -> ()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomTrailing) {
        Button(action: open) {
          MadeForYouArt(mix: mix, coverPaths: coverPaths, side: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
            .contentShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mix.title)
        .accessibilityHint("Opens the playlist")

        CassettePlayDisc(action: play)
          .padding(8)
      }
      .frame(width: Self.side, height: Self.side)

      Button(action: open) {
        VStack(alignment: .leading, spacing: 2) {
          Text(mix.title)
            .font(Font.cassette(.rowTitle))
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(1)
          Text("\(mix.songs.count) songs")
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
}

// MARK: - MadeForYouArt

/// A made-for-you playlist's picture at `side`: a 2x2 of covers from it (repeated when it
/// has fewer than four, the ring art when none is on disk yet), or, for a mood mix, the
/// mood's colour and shape (MoodDoorArt). No words on it: the name sits underneath.
struct MadeForYouArt: View {
  let mix: HomeManager.MadeForYouMix
  let coverPaths: [String]
  let side: CGFloat

  var body: some View {
    Group {
      if case let .mood(key, hexColor) = mix.kind {
        MoodMixArt(key: key, hexColor: hexColor)
      } else if coverPaths.isEmpty {
        MoodMixArt(key: "lately", hexColor: "#B07AA1")
      } else {
        mosaic
      }
    }
    .frame(width: side, height: side)
  }

  /// Four slots, filled in mix order and repeated to make four.
  private var mosaic: some View {
    let slots = (0 ..< 4).map { coverPaths[$0 % coverPaths.count] }
    let half = side / 2
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        LatelyCover(path: slots[0], side: half)
        LatelyCover(path: slots[1], side: half)
      }
      HStack(spacing: 0) {
        LatelyCover(path: slots[2], side: half)
        LatelyCover(path: slots[3], side: half)
      }
    }
  }
}

// MARK: - MoodMixArt

/// A mood mix's picture: the door's colour washing in from the top-left and its shape
/// (MoodDoors.swift), with no label. Fills its frame.
struct MoodMixArt: View {
  let key: String
  let hexColor: String

  var body: some View {
    let color = Color(hexString: hexColor) ?? Color.cassette(.textSecondary)
    let shape = MoodDoors.all.first(where: { $0.key == key })?.shape ?? .concentricRings
    return ZStack {
      Color.cassette(.surfaceElevated)
      LinearGradient(
        stops: [
          .init(color: color.opacity(0.45), location: 0),
          .init(color: .clear, location: 0.75),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      MoodDoorArt(shape: shape, color: color)
    }
  }
}

// MARK: - LatelyCover

/// One square of a mosaic: the cover decoded small off the main thread, from the cache
/// when it has been decoded before. bg3 until it lands.
struct LatelyCover: View {
  let path: String
  let side: CGFloat

  @State
  private var image: UIImage?

  init(path: String, side: CGFloat) {
    self.path = path
    self.side = side
    _image = State(initialValue: LatelyCoverCache.cached(path))
  }

  var body: some View {
    ZStack {
      Color.cassette(.surfaceElevated)
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
    }
    .frame(width: side, height: side)
    .clipped()
    .accessibilityHidden(true)
    .task(id: path) {
      guard image == nil else { return }
      image = await LatelyCoverCache.load(path)
    }
  }
}

// MARK: - LatelyCoverCache

/// Mosaic covers, decoded once at 360px off the main thread and kept by path. Static,
/// because Home re-hosts this row on every configure, which resets any @State.
@MainActor
enum LatelyCoverCache {
  private static let cache = NSCache<NSString, UIImage>()

  static func cached(_ path: String) -> UIImage? {
    cache.object(forKey: path as NSString)
  }

  static func load(_ path: String) async -> UIImage? {
    if let hit = cached(path) { return hit }
    let image = await Task.detached(priority: .utility) {
      AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: 360)
    }.value
    if let image {
      cache.setObject(image, forKey: path as NSString)
    }
    return image
  }
}
