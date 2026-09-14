//
//  MoodDoorTile.swift
//  Amperfy
//
//  Cassette: one Home "Mood" tile. Same glow-wash + procedural-pattern
//  treatment as the web app's tiles (color wash behind, MoodDoorArt motif,
//  name overlaid at the bottom) — NOT flattened to a plain color block; the
//  card CHROME (3pt corner radius, no stroke, no shadow) matches
//  AlbumCollectionCell, but the CONTENT stays colorful/textured like web.
//  No "Playlist" kicker or sub-copy line on the card itself — just the name.

import AmperfyKit
import SwiftUI

struct MoodDoorTile: View {
  let door: MoodDoor
  let isBusy: Bool
  let onTap: () -> ()

  private var color: Color {
    Color(hexString: door.hexColor) ?? CassetteTheme.Colors.orange
  }

  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .bottomLeading) {
        CassetteTheme.Colors.bg2

        LinearGradient(
          colors: [color.opacity(0.4), .clear],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        MoodDoorArt(shape: door.shape, color: color)

        Text(door.label)
          .font(Font.cassette(.rowTitle))
          .foregroundStyle(CassetteTheme.Colors.ink)
          .lineLimit(1)
          .padding(10)

        if isBusy {
          Color.black.opacity(0.35)
          ProgressView()
            .tint(CassetteTheme.Colors.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: 170, height: 130)
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }
}
