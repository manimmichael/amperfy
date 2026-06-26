//
//  DiagnosticsSettingsView.swift
//  Amperfy
//
//  Cassette fork — Diagnostics Phase 1 (on-device diagnostics surface).
//
//  The deliberate, release-visible counterpart to the Siri trigger. Lives on the
//  Advanced screen (next to the Event Log). It lets the founder flag a moment by
//  hand, see the live rolling buffer, and export the full trace via the share
//  sheet — the full buffer, not the 30-event cap the support email carries.
//
//  Export uses SwiftUI's native `ShareLink` (NOT a UIActivityViewController
//  wrapped in a `.sheet` — that presents blank, since the activity controller
//  expects to be presented directly rather than hosted as a sheet's root). The
//  shared file is regenerated on every refresh so it always reflects the latest
//  buffer.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - DiagnosticsSettingsView

struct DiagnosticsSettingsView: View {
  @State
  private var entries: [DiagnosticEntry] = []
  @State
  private var exportURL: URL?

  var body: some View {
    ZStack {
      List {
        Section(
          footer: Text(
            "An always-on, in-memory trace of playback, CarPlay and server activity. Flag a moment to bookmark it, then export the full trace to share it."
          )
        ) {
          Button {
            flagMoment()
          } label: {
            Label("Flag this moment", systemImage: "flag.fill")
          }
          if let exportURL {
            ShareLink(item: exportURL) {
              Label("Export diagnostics", systemImage: "square.and.arrow.up")
            }
          }
        }

        Section(header: Text("Recent activity (\(entries.count))")) {
          if entries.isEmpty {
            Text("No events captured yet.")
              .foregroundColor(.secondary)
          } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
              DiagnosticEntryRow(entry: entry)
            }
          }
        }
      }
      .listStyle(.grouped)
    }
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refresh()
      regenerateExportFile()
    }
    .refreshable { refresh() }
  }

  // MARK: Actions

  /// Cheap: just re-snapshot the buffer (newest-first). Used by pull-to-refresh.
  /// Export-file regeneration is deliberately separate — it does a heavier
  /// main-actor collect + encode, so it only runs on appear and after a flag,
  /// not on every pull-to-refresh.
  private func refresh() {
    entries = Array(DiagnosticLog.shared.snapshot().reversed())
  }

  private func flagMoment() {
    DiagnosticLog.shared.mark("Flagged from Settings", context: ["source": "settings"])
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    refresh()
    regenerateExportFile() // keep the export current so a just-flagged moment is shareable
  }

  /// Writes the full diagnostics payload (device/player/library context + the
  /// complete rolling trace, no 30-event cap) to a stable temp file that
  /// `ShareLink` shares.
  private func regenerateExportFile() {
    guard let data = LogData.collectInformation(amperfyData: AmperKit.shared).asJSONData()
    else { return }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CassetteDiagnostics.json")
    do {
      try data.write(to: url, options: .atomic)
      exportURL = url
    } catch {
      // Best-effort; leave the previous export URL (if any) in place.
    }
  }
}

// MARK: - DiagnosticEntryRow

private struct DiagnosticEntryRow: View {
  let entry: DiagnosticEntry

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(entry.category.rawValue.uppercased())
          .font(.caption2.monospaced())
          .foregroundColor(.secondary)
        Spacer()
        Text(Self.timeFormatter.string(from: entry.timestamp))
          .font(.caption2.monospaced())
          .foregroundColor(.secondary)
      }
      Text(entry.message)
        .font(.callout)
      if let context = entry.context, !context.isEmpty {
        Text(context.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "  ·  "))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - DiagnosticsSettingsView_Previews

struct DiagnosticsSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    DiagnosticsSettingsView()
  }
}
