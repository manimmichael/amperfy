//
//  DiagnosticPlayerObserver.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 1 (playback breadcrumbs).
//
//  A `MusicPlayable` subscriber registered on the player alongside the existing
//  notifiers (NowPlayingInfoCenterHandler, ScrobbleSyncer, …). It mirrors player
//  STATE TRANSITIONS into the rolling diagnostic log and deliberately DROPS the
//  ~1/sec elapsed-time and lyrics-time heartbeats so the buffer captures
//  behaviour, not the scrubber. Playback ERRORS are not logged here — they
//  already funnel through `EventLogger`, which the diagnostic log taps centrally.
//
//  `append` is fire-and-return, so these callbacks never block the player.
//

import Foundation

// MARK: - DiagnosticPlayerObserver

@MainActor
final class DiagnosticPlayerObserver: MusicPlayable {
  /// Best-effort current-track title, read on the main actor at call time.
  private let currentTitle: @MainActor () -> String?

  init(currentTitle: @escaping @MainActor () -> String?) {
    self.currentTitle = currentTitle
  }

  private func trackContext() -> [String: String]? {
    guard let title = currentTitle(), !title.isEmpty else { return nil }
    return ["track": title]
  }

  // MARK: State transitions (logged)

  func didStartPlayingFromBeginning() {
    DiagnosticLog.shared.log(.playback, "track started", context: trackContext())
  }

  func didStartPlaying() {
    DiagnosticLog.shared.log(.playback, "play / resume", context: trackContext())
  }

  func didPause() {
    DiagnosticLog.shared.log(.playback, "pause", context: trackContext())
  }

  func didStopPlaying() {
    DiagnosticLog.shared.log(.playback, "stop")
  }

  func didPlaylistChange() {
    DiagnosticLog.shared.log(.playback, "queue changed")
  }

  func didShuffleChange() {
    DiagnosticLog.shared.log(.playback, "shuffle toggled")
  }

  func didRepeatChange() {
    DiagnosticLog.shared.log(.playback, "repeat mode changed")
  }

  func didPlaybackRateChange() {
    DiagnosticLog.shared.log(.playback, "playback rate changed")
  }

  // MARK: Heartbeat / noise (intentionally dropped)

  /// Fires ~once per second during playback — the scrubber tick. Dropping it is
  /// the single most important guardrail for buffer/perf health.
  func didElapsedTimeChange() {}

  /// Artwork can swap placeholder→real several times per track; not signal.
  func didArtworkChange() {}
}
