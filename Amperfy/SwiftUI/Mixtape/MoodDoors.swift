//
//  MoodDoors.swift
//  Amperfy
//
//  Cassette: the six Home "Mood" tiles (Get Pumped, Road Trip, Focus, Wind
//  Down, Late Night, Feel Good) — client-side just needs a key, label,
//  sub-copy, and a color to render a tile and POST { door_key } to
//  /api/mixtape/door. All the actual scenario/mood scoring stays server-side
//  in the web app's lib/mixtape/mood-doors.ts; these hex values are copied
//  from that file so the two platforms read as the same product.

import SwiftUI

// MARK: - MoodDoorShape

/// Mirrors web's MoodTileShape (lib/mixtape/mood-doors.ts + MoodTileArt.tsx) —
/// same six procedural motifs, drawn natively in MoodDoorArt.swift instead of
/// as SVG.
enum MoodDoorShape {
  case radialBloom
  case dotGrid
  case diagonalStripes
  case concentricRings
  case diamondOutline
  case hatchLines
}

// MARK: - MoodDoor

struct MoodDoor: Identifiable {
  let key: String
  let label: String
  let sub: String
  let hexColor: String
  let shape: MoodDoorShape

  var id: String { key }
}

// MARK: - MoodDoors

enum MoodDoors {
  static let all: [MoodDoor] = [
    MoodDoor(
      key: "get-pumped",
      label: "Get Pumped",
      sub: "Workout · Hype · Victory lap",
      hexColor: "#E8452C",
      shape: .diagonalStripes
    ),
    MoodDoor(
      key: "road-trip",
      label: "Road Trip",
      sub: "Driving · Singalong · Summer anthem",
      hexColor: "#D4A020",
      shape: .radialBloom
    ),
    MoodDoor(
      key: "focus",
      label: "Focus",
      sub: "Studying · Coding · Background",
      hexColor: "#3A7CA5",
      shape: .concentricRings
    ),
    MoodDoor(
      key: "wind-down",
      label: "Wind Down",
      sub: "Sunday morning · Rainy day",
      hexColor: "#4A9B8E",
      shape: .dotGrid
    ),
    MoodDoor(
      key: "late-night",
      label: "Late Night",
      sub: "Three AM feelings · Comedown",
      hexColor: "#6B4FA0",
      shape: .hatchLines
    ),
    MoodDoor(
      key: "feel-good",
      label: "Feel Good",
      sub: "Party · Celebration · New love",
      hexColor: "#D64B8C",
      shape: .diamondOutline
    ),
  ]
}

extension Color {
  /// Parses a "#RRGGBB" or "RRGGBB" string (the wire format the mixtape API's
  /// `art.color` field and MoodDoor.hexColor use) — same RGB math as
  /// CassetteTheme's `UIColor.cassetteHex(_:)`, just string-sourced instead
  /// of a `0x` literal. nil on anything that isn't exactly 6 hex digits.
  init?(hexString: String) {
    var hex = hexString
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    self.init(red: r, green: g, blue: b)
  }
}
