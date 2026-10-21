//
//  MoodDoorRow.swift
//  Amperfy
//
//  Cassette: the Home "Mood" shelf content - the Lately tile and the six MoodDoorTiles
//  in a horizontal scroll. Owns the actual /api/mixtape/door call + per-tile busy
//  state; hands the result up via `onGenerated` so the UIKit side
//  (MoodDoorsHeaderView) can present MixtapePreviewSheet as a real sheet -
//  SwiftUI here has no view controller of its own to present from.
//
//  cassette 2026-10-20: the first tile is "Lately", a mix of songs on this phone that
//  match the mood of what the person has been playing (ListeningShelves). It is built on
//  the phone and plays at once, so it shows for every account with a mix; the six
//  server doors still need the Mixtape beta.
//
//  phone-taste (approved phone mock, 2026-10-20): the row reads like every other Home row
//  (a MOOD shout, the shelf's 20pt gutter and 12pt gap, 150pt square tiles), and the
//  Lately tile shows the records it will play: a 2x2 of covers from HomeManager's Lately
//  mix, with the one-tap play disc. The row never builds the mix itself; it draws and
//  plays the one HomeManager built (`latelyMix`).
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - MoodDoorRow

struct MoodDoorRow: View {
  /// HomeManager's Lately mix. nil or empty: no Lately tile.
  let latelyMix: HomeManager.LatelyMix?
  let onGenerated: (CassetteMixtapeResponse) -> ()

  @State
  private var busyKey: String?
  @State
  private var errorMessage: String?

  /// The mock's `.shelf` gap.
  private static let tileSpacing: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: CassetteHeading.bottomSpacing) {
      // The same two-voice heading, gutter and air as the UIKit rows around it.
      CassetteHeadingText(shout: "MOOD")
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.top, CassetteHeading.topSpacing)

      if let errorMessage {
        Text(errorMessage)
          .font(Font.cassette(.caption))
          .foregroundStyle(Color.cassette(.danger))
          .padding(.horizontal, CassetteHeading.sideInset)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Self.tileSpacing) {
          if let latelyMix, !latelyMix.songs.isEmpty {
            LatelyMixTile(coverPaths: coverPaths(of: latelyMix)) {
              play(latelyMix)
            }
          }
          ForEach(CassetteBetaAccess.isBetaTester ? MoodDoors.all : []) { door in
            MoodDoorTile(door: door, isBusy: busyKey == door.key) {
              generate(door: door)
            }
          }
        }
        .padding(.horizontal, AlbumCarousel.mockGutter)
      }
    }
    // The cover shelves' bottom inset (the next row's heading brings its own 28pt).
    .padding(.bottom, 2)
  }

  /// The mix's lead albums' covers that are on disk, in mix order.
  private func coverPaths(of mix: HomeManager.LatelyMix) -> [String] {
    let settings = appDelegate.storage.settings.accounts
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

  /// Plays exactly the mix the tile shows: songs on this phone, matching lately.
  private func play(_ mix: HomeManager.LatelyMix) {
    guard !mix.songs.isEmpty else { return }
    appDelegate.player.play(context: PlayContext(name: "Lately", playables: mix.songs))
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  private func generate(door: MoodDoor) {
    guard busyKey == nil else { return }
    busyKey = door.key
    errorMessage = nil
    Task {
      do {
        let mixtape = try await CassetteSyncAPI.shared.generateDoorMixtape(doorKey: door.key)
        await MainActor.run {
          busyKey = nil
          onGenerated(mixtape)
        }
      } catch {
        await MainActor.run {
          busyKey = nil
          // cassette (BUG-348): a 404 means the account left the Mixtape beta since
          // this shelf was drawn; say so instead of blaming the build.
          if case CassetteSyncError.http(404) = error {
            errorMessage = "Mixtape is in beta. Join it from your account page on cassette.digital."
          } else {
            errorMessage = "Couldn't build \"\(door.label)\" right now"
          }
        }
      }
    }
  }
}

// MARK: - LatelyMixTile

/// The Lately tile (the mock's first `.door` with its `.mosaic`): a 150pt square of four
/// covers from the mix, 75pt each with square corners (repeated when the mix has fewer
/// than four), darkening toward the bottom, "Lately" at the bottom-left and the one-tap
/// play disc at the bottom-right. With no cover on disk it falls back to the ring art.
/// Tapping the tile or the disc plays the mix. The disc is a sibling of the tile's
/// button, never inside it (in SwiftUI the outer button's tap would win).
private struct LatelyMixTile: View {
  static let coverSide: CGFloat = MoodDoorTile.side / 2
  /// The ring art's colour, from before the tile showed covers.
  private static let ringHex = "#B07AA1"

  let coverPaths: [String]
  let play: () -> ()

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Button(action: play) {
        face
          .frame(width: MoodDoorTile.side, height: MoodDoorTile.side)
          .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.control))
          .contentShape(RoundedRectangle(cornerRadius: CassetteRadius.control))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Lately")

      CassettePlayDisc(action: play)
        .padding(8)
    }
    .frame(width: MoodDoorTile.side, height: MoodDoorTile.side)
  }

  private var face: some View {
    ZStack(alignment: .bottomLeading) {
      if coverPaths.isEmpty {
        ringArt
      } else {
        mosaic
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.4),
            .init(color: Color.cassette(.surfaceSunken).opacity(0.75), location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      MoodTileLabel(text: "Lately")
    }
  }

  /// Four slots, filled in mix order and repeated to make four.
  private var mosaic: some View {
    let slots = (0 ..< 4).map { coverPaths[$0 % coverPaths.count] }
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        LatelyCover(path: slots[0])
        LatelyCover(path: slots[1])
      }
      HStack(spacing: 0) {
        LatelyCover(path: slots[2])
        LatelyCover(path: slots[3])
      }
    }
  }

  private var ringArt: some View {
    let color = Color(hexString: Self.ringHex) ?? Color.cassette(.textSecondary)
    return ZStack {
      Color.cassette(.surfaceElevated)
      LinearGradient(
        stops: [
          .init(color: color.opacity(0.4), location: 0),
          .init(color: .clear, location: 0.7),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      MoodDoorArt(shape: .concentricRings, color: color)
    }
  }
}

// MARK: - LatelyCover

/// One square of the Lately mosaic: the cover decoded small off the main thread, from
/// the cache when it has been decoded before. bg3 until it lands.
private struct LatelyCover: View {
  let path: String

  @State
  private var image: UIImage?

  init(path: String) {
    self.path = path
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
    .frame(width: LatelyMixTile.coverSide, height: LatelyMixTile.coverSide)
    .clipped()
    .accessibilityHidden(true)
    .task(id: path) {
      guard image == nil else { return }
      image = await LatelyCoverCache.load(path)
    }
  }
}

// MARK: - LatelyCoverCache

/// The Lately covers, decoded once at 240px off the main thread and kept by path. Static,
/// because Home re-hosts the Mood row on every configure, which resets any @State.
@MainActor
private enum LatelyCoverCache {
  private static let cache = NSCache<NSString, UIImage>()

  static func cached(_ path: String) -> UIImage? {
    cache.object(forKey: path as NSString)
  }

  static func load(_ path: String) async -> UIImage? {
    if let hit = cached(path) { return hit }
    let image = await Task.detached(priority: .utility) {
      AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: 240)
    }.value
    if let image {
      cache.setObject(image, forKey: path as NSString)
    }
    return image
  }
}
