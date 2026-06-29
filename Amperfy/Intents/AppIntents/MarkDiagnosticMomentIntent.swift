//
//  MarkDiagnosticMomentIntent.swift
//  Amperfy
//
//  Cassette fork — Diagnostics Phase 1 ("mark this moment" trigger).
//
//  The hands-free trigger. A Siri phrase / Shortcut that drops a marker into the
//  rolling diagnostic log and forces a snapshot to disk — the highest-value
//  trigger while driving, since it needs no glance or tap. Runs in the
//  background (`openAppWhenRun = false`) so saying it never yanks the driver
//  into the app. Registered as an `AppShortcut` in AmperfyAppShortcuts.swift.
//

import AmperfyKit
import AppIntents
import Foundation

// MARK: - MarkDiagnosticMomentIntent

struct MarkDiagnosticMomentIntent: AppIntent {
  static let intentClassName = "MarkDiagnosticMomentIntent"
  static let title: LocalizedStringResource = "Flag a Moment"
  static let description =
    IntentDescription(
      "Marks the current moment in Cassette's diagnostic log, making it easy to find what the app was doing."
    )

  // Stay in the background — the point is to flag without interrupting playback
  // or pulling a driver into the app.
  static let openAppWhenRun = false

  @Parameter(title: "Note", default: "Flagged")
  var note: String

  static var parameterSummary: some ParameterSummary {
    Summary("Flag a moment in Cassette")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    DiagnosticLog.shared.mark(note, context: ["source": "appIntent"])
    return .result()
  }
}
