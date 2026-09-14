//
//  MoodDoorRow.swift
//  Amperfy
//
//  Cassette: the Home "Mood" shelf content — six MoodDoorTiles in a
//  horizontal scroll. Owns the actual /api/mixtape/door call + per-tile busy
//  state; hands the result up via `onGenerated` so the UIKit side
//  (MoodDoorsHeaderView) can present MixtapePreviewSheet as a real sheet —
//  SwiftUI here has no view controller of its own to present from.

import AmperfyKit
import SwiftUI

struct MoodDoorRow: View {
  let onGenerated: (CassetteMixtapeResponse) -> ()

  @State
  private var busyKey: String?
  @State
  private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Same font/color/insets as SectionHeaderView's .shelf style
      // (HomeVC.swift) — Barlow Bold 22, full ink, 16pt leading/top,
      // no letter-spacing — so "Mood" reads identically to "Recent"/
      // "Playlists" above and below it, not as a smaller mono label.
      Text("Mood")
        .font(Font.cassette(.sectionTitle))
        .foregroundStyle(CassetteTheme.Colors.ink)
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
          ForEach(MoodDoors.all) { door in
            MoodDoorTile(door: door, isBusy: busyKey == door.key) {
              generate(door: door)
            }
          }
        }
        .padding(.horizontal, 16)
      }
    }
    .padding(.bottom, 8)
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
