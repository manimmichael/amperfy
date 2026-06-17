//
//  AudioSessionHandler.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 23.11.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import MediaPlayer
import os.log

@MainActor
public class AudioSessionHandler {
  var musicPlayer: AudioPlayer?
  var eventLogger: EventLogger?

  /// Patch 113 (step 2): tracks whether WE have activated the session, so the
  /// per-track `configureBackgroundPlayback()` becomes a no-op once active
  /// (setActive(true) on every skip is a main-thread staller). Reset to false
  /// when the OS deactivates us (interruption began); the .ended-resume path
  /// reactivates explicitly.
  private var isSessionActive = false

  /// A2: true between an interruption's `.began` and `.ended`. While set,
  /// `configureBackgroundPlayback()` must NOT call `setActive(true)` — a late
  /// stream insert or an auto-advance landing during a phone call would
  /// otherwise slam our session active over the call (the over-call incident).
  /// Reactivation happens only via the `.ended` + `.shouldResume` path.
  private var isInterrupted = false

  func configureObserverForAudioSessionInterruption() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  @objc
  private func handleAudioSessionInterruption(notification: NSNotification) {
    guard let interruptionTypeRaw: NSNumber = notification
      .userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
      let interruptionType = AVAudioSession
      .InterruptionType(rawValue: interruptionTypeRaw.uintValue) else {
      os_log(.error, "Audio Session: Audio interruption type invalid")
      return
    }

    switch interruptionType {
    case AVAudioSession.InterruptionType.began:
      // Audio has stopped, already inactive
      // Change state of UI, etc., to reflect non-playing state
      os_log(.info, "Audio Session: Audio interruption began")
      // The system deactivates our session during the interruption; mark it so
      // resume reactivates it (Patch 113 step 2).
      isSessionActive = false
      isInterrupted = true
      musicPlayer?.pause()
    case AVAudioSession.InterruptionType.ended:
      // Make session active
      // Update user interface
      // AVAudioSessionInterruptionOptionShouldResume option
      os_log(.info, "Audio Session: Audio interruption ended")
      // Interruption is over: clear the gate so the reactivation below (and any
      // subsequent user-initiated play) can activate the session again.
      isInterrupted = false
      if let interruptionOptionRaw: NSNumber = notification
        .userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber {
        let interruptionOption = AVAudioSession
          .InterruptionOptions(rawValue: interruptionOptionRaw.uintValue)
        if interruptionOption == AVAudioSession.InterruptionOptions.shouldResume {
          // Here you should continue playback
          os_log(.info, "Audio Session: Audio interruption ended -> Resume playing")
          // Reactivate the session before resuming — the resume path may go
          // through continuePlay, which doesn't reconfigure (Patch 113 step 2).
          configureBackgroundPlayback()
          musicPlayer?.play()
        }
      }
    default: break
    }
  }

  @objc
  private func handleRouteChange(notification: NSNotification) {
    os_log(.info, "Audio Session: route changed")
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }

    switch reason {
    case .newDeviceAvailable:
      let session = AVAudioSession.sharedInstance()
      for output in session.currentRoute.outputs where
        output.portType == AVAudioSession.Port.headphones ||
        output.portType == AVAudioSession.Port.bluetoothA2DP {
        os_log(.info, "Audio Session: headphones connected")
        Task { @MainActor in
          self.musicPlayer?.play()
        }
        break
      }
    case .oldDeviceUnavailable:
      if let previousRoute =
        userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
        for output in previousRoute.outputs where
          output.portType == AVAudioSession.Port.headphones ||
          output.portType == AVAudioSession.Port.bluetoothA2DP {
          os_log(.info, "Audio Session: headphones disconnected")
          Task { @MainActor in
            self.musicPlayer?.pause()
          }
          break
        }
      }
    default: break
    }
  }

  func configureBackgroundPlayback() {
    // A2: never (re)activate the session while an interruption is active. A
    // late stream insert or auto-advance during a phone call would otherwise
    // `setActive(true)` over the call. Reactivation is owned solely by the
    // `.ended` + `.shouldResume` path, which clears `isInterrupted` first.
    guard !isInterrupted else { return }
    // Patch 113 (step 2): activate once. Once active, this is a no-op so a skip
    // no longer pays for setActive(true). Reactivated after interruptions via
    // the isSessionActive reset above.
    guard !isSessionActive else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
      try AVAudioSession.sharedInstance().setActive(true)
      isSessionActive = true
    } catch {
      eventLogger?.report(topic: "Audio Session", error: error)
    }
  }
}
