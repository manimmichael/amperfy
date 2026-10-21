//
//  MoodDoorRow.swift
//  Amperfy
//
//  Cassette: the Home "Mood" shelf content — six MoodDoorTiles in a
//  horizontal scroll. Owns the actual /api/mixtape/door call + per-tile busy
//  state; hands the result up via `onGenerated` so the UIKit side
//  (MoodDoorsHeaderView) can present MixtapePreviewSheet as a real sheet —
//  SwiftUI here has no view controller of its own to present from.
//
//  cassette 2026-10-20: the first tile is "Lately", a mix of songs on this phone that
//  match the mood of what the person has been playing (ListeningShelves). It is built on
//  the phone and plays at once, so it shows for every account with mood tags; the six
//  server doors still need the Mixtape beta.

import AmperfyKit
import SwiftUI

struct MoodDoorRow: View {
  let onGenerated: (CassetteMixtapeResponse) -> ()

  @State
  private var busyKey: String?
  @State
  private var errorMessage: String?
  @State
  private var latelySub: String?

  private static let latelyMixLength = 40

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Same font/color/insets as SectionHeaderView's .shelf style
      // (HomeVC.swift) — Barlow Bold 22, full ink, 16pt leading/top,
      // no letter-spacing — so "Mood" reads identically to "Recent"/
      // "Playlists" above and below it, not as a smaller mono label.
      Text("Mood")
        .font(Font.cassette(.sectionTitle))
        .foregroundStyle(Color.cassette(.textPrimary))
        .padding(.horizontal, 16)
        .padding(.top, 16)

      if let errorMessage {
        Text(errorMessage)
          .font(Font.cassette(.caption))
          .foregroundStyle(.red)
          .padding(.horizontal, 16)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          if let latelySub {
            MoodDoorTile(door: Self.latelyDoor(sub: latelySub), isBusy: false) {
              playLately()
            }
          }
          ForEach(CassetteBetaAccess.isBetaTester ? MoodDoors.all : []) { door in
            MoodDoorTile(door: door, isBusy: busyKey == door.key) {
              generate(door: door)
            }
          }
        }
        .padding(.horizontal, 16)
      }
    }
    .padding(.bottom, 8)
    .onAppear { latelySub = latelySnapshot()?.describe }
  }

  private static func latelyDoor(sub: String) -> MoodDoor {
    MoodDoor(
      key: "lately",
      label: "Lately",
      sub: sub,
      hexColor: "#B07AA1",
      shape: .concentricRings
    )
  }

  private func latelySnapshot() -> LatelyLibrary.Snapshot? {
    let storage = appDelegate.storage
    guard let info = storage.settings.accounts.active else { return nil }
    return LatelyLibrary.snapshot(storage: storage, account: storage.main.library.getAccount(info: info))
  }

  /// Build the mix from the songs on this phone and play it straight away.
  private func playLately() {
    guard let snapshot = latelySnapshot() else { return }
    var rng = SystemRandomNumberGenerator()
    let ids = ListeningShelves.latelyMix(
      snapshot.songCandidates,
      profile: snapshot.profile,
      playedRecently: snapshot.songsPlayedRecently,
      count: Self.latelyMixLength,
      using: &rng
    )
    let songs: [AbstractPlayable] = ids.compactMap { snapshot.songsByID[$0] }
    guard !songs.isEmpty else {
      errorMessage = "Not enough music on this phone matches lately yet"
      return
    }
    appDelegate.player.play(context: PlayContext(name: "Lately", playables: songs))
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
