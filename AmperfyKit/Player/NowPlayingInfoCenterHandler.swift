//
//  NowPlayingInfoCenterHandler.swift
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

// MARK: - NowPlayingInfoCenterHandler

@MainActor
public class NowPlayingInfoCenterHandler {
  private let musicPlayer: AudioPlayer
  private let backendAudioPlayer: BackendAudioPlayer
  private let storage: PersistentStorage
  private var nowPlayingInfoCenter: MPNowPlayingInfoCenter
  private let getArtworkDownloaderCB: GetArtworkDownloadManagerCallback
  private var accountNotificationHandler: AccountNotificationHandler?
  // cassette (art stability): the album-cover path currently applied to the
  // now-playing artwork, set ONLY when a REAL cover (not a placeholder) is shown.
  // Consecutive tracks of the same album share this path, so we leave the artwork
  // untouched across a track change instead of rebuilding MPMediaItemArtwork and
  // making CarPlay's hero blink. nil = a placeholder is showing (so the real cover,
  // when it lands, is not mistaken for "already up to date").
  private var currentArtworkKey: String?
  // The album identity behind the currently-shown artwork. Lets us tell a
  // genuinely different (also cover-less) album apart from the same album still
  // downloading its cover — so advancing between two cover-less albums swaps to the
  // new album's monogram instead of keeping the previous one's.
  private var currentArtworkAlbumKey: String?

  init(
    musicPlayer: AudioPlayer,
    backendAudioPlayer: BackendAudioPlayer,
    nowPlayingInfoCenter: MPNowPlayingInfoCenter,
    storage: PersistentStorage,
    notificationHandler: EventNotificationHandler,
    getArtworkDownloaderCB: @escaping GetArtworkDownloadManagerCallback,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback
  ) {
    self.musicPlayer = musicPlayer
    self.backendAudioPlayer = backendAudioPlayer
    self.nowPlayingInfoCenter = nowPlayingInfoCenter
    self.storage = storage
    self.getArtworkDownloaderCB = getArtworkDownloaderCB

    nowPlayingInfoCenter.playbackState = .stopped

    self.accountNotificationHandler = AccountNotificationHandler(
      storage: storage,
      notificationHandler: notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: getArtworkDownloaderCB(accountInfo)
      )
      notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: getPlayableDownloaderCB(accountInfo)
      )
    }
  }

  private func updateNowPlayingInfo(playable: AbstractPlayable) {
    let albumTitle = playable.asSong?.album?.name ?? ""
    let nowPlaying = displayNowPlayingInfo(for: playable)

    // cassette (art stability): MUTATE the existing dict (like updateElapsedTime)
    // instead of rebuilding it. Metadata changes every track; the artwork usually
    // does NOT (all tracks of an album share one cover). Reassigning
    // MPMediaItemArtwork on every track change makes CarPlay re-fetch and blink the
    // hero — so we only touch the artwork when the cover actually changes.
    var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyMediaType] =
      NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
    info[MPNowPlayingInfoPropertyServiceIdentifier] = AmperKit.name
    info[MPMediaItemPropertyIsCloudItem] = !playable.isCached
    info[MPMediaItemPropertyTitle] = nowPlaying.title
    info[MPMediaItemPropertyAlbumTitle] = albumTitle
    info[MPMediaItemPropertyArtist] = nowPlaying.artist
    info[MPMediaItemPropertyPlaybackDuration] = backendAudioPlayer.duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = backendAudioPlayer.elapsedTime
    info[MPNowPlayingInfoPropertyIsLiveStream] = playable.isRadio
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = NSNumber(value: 1.0)
    info[MPNowPlayingInfoPropertyPlaybackRate] =
      NSNumber(value: backendAudioPlayer.playbackRate.asDouble)

    if let accountInfo = playable.account?.info {
      let settings = storage.settings.accounts.getSetting(accountInfo).read
      // Album-first cover path; nil when no cover file is on disk (yet).
      let coverKey = playable.imagePath(setting: settings.artworkDisplayPreference)
      let hasArtwork = info[MPMediaItemPropertyArtwork] != nil
      // Stable per-album identity so a cover-less album is told apart from another.
      let albumKey = playable.asSong?.album?.id ?? playable.uniqueID

      if coverKey != nil, coverKey == currentArtworkKey, hasArtwork {
        // Same album cover already shown — leave the artwork untouched (no blink).
      } else if coverKey != nil {
        // A real cover is on disk — apply it once and remember its identity.
        let img = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: playable,
          themePreference: settings.themePreference,
          artworkDisplayPreference: settings.artworkDisplayPreference,
          useCache: true
        )
        info[MPMediaItemPropertyArtwork] = makeNowPlayingArtwork(img)
        currentArtworkKey = coverKey
        currentArtworkAlbumKey = albumKey
      } else if !hasArtwork || albumKey != currentArtworkAlbumKey {
        // No cover on disk. Show THIS album's placeholder when nothing is shown yet,
        // OR when a DIFFERENT (also cover-less) album is now playing — otherwise the
        // lock screen keeps the previous album's monogram. downloadFinishedSuccessful
        // replaces it when a real cover lands.
        let img = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: playable,
          themePreference: settings.themePreference,
          artworkDisplayPreference: settings.artworkDisplayPreference,
          useCache: true
        )
        info[MPMediaItemPropertyArtwork] = makeNowPlayingArtwork(img)
        currentArtworkKey = nil
        currentArtworkAlbumKey = albumKey
      }
      // else: SAME cover-less album, cover still downloading — KEEP what's shown
      // rather than flashing a placeholder.

      // Enqueue the album-first cover so a missing one lands (C09).
      if let heroArtwork = playable.asSong?.album?.artwork ?? playable.artwork {
        getArtworkDownloaderCB(accountInfo).download(object: heroArtwork)
      }
    }

    nowPlayingInfoCenter.nowPlayingInfo = info
  }

  private func makeNowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    let safe = image
    return MPMediaItemArtwork(boundsSize: safe.size) { @Sendable _ -> UIImage in
      // this completion handler is not called on the main thread!
      safe
    }
  }

  /// Patch 113 (responsiveness, step 1): per-second elapsed updates must NOT
  /// rebuild the whole dict or re-decode artwork. Mutate only the time/rate
  /// keys on the existing nowPlayingInfo; fall back to a full build only if no
  /// base dict exists yet (e.g. first tick before didStartPlaying).
  private func updateElapsedTime() {
    guard var info = nowPlayingInfoCenter.nowPlayingInfo else {
      if let curPlayable = musicPlayer.currentlyPlaying {
        updateNowPlayingInfo(playable: curPlayable)
      }
      return
    }
    info[MPMediaItemPropertyPlaybackDuration] = backendAudioPlayer.duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = backendAudioPlayer.elapsedTime
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = NSNumber(value: 1.0)
    info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(
      value: backendAudioPlayer.playbackRate
        .asDouble
    )
    nowPlayingInfoCenter.nowPlayingInfo = info
  }

  private func displayNowPlayingInfo(for playable: AbstractPlayable) -> RadioNowPlayingInfo {
    if playable.isRadio,
       let radioInfo = musicPlayer.currentRadioNowPlaying,
       !radioInfo.isEmpty {
      return radioInfo
    }
    return RadioNowPlayingInfo(title: playable.title, artist: playable.creatorName)
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = musicPlayer.currentlyPlaying
    else { return }
    // cassette (C09): the hero renders the ALBUM-first cover, so match the album's
    // artwork id too — otherwise an album-cover download completing never rebuilds
    // the hero (song id and song-own artwork id both miss the album cover).
    let albumArtworkID = curPlayable.asSong?.album?.artwork?.uniqueID
    if curPlayable.uniqueID == downloadNotification.id
      || curPlayable.artwork?.uniqueID == downloadNotification.id
      || albumArtworkID == downloadNotification.id {
      // Force a re-apply: a cover CORRECTED in place (a folder swap re-pulled to the
      // SAME file path) leaves coverKey unchanged, so updateNowPlayingInfo's
      // same-key guard would otherwise keep the stale artwork on the lock screen /
      // CarPlay hero until the album changed. Clearing the key drops into the
      // apply branch, which re-decodes the now-evicted cache from the new bytes.
      currentArtworkKey = nil
      Task { @MainActor in
        updateNowPlayingInfo(playable: curPlayable)
      }
    }
  }
}

// MARK: MusicPlayable

extension NowPlayingInfoCenterHandler: MusicPlayable {
  public func didStartPlayingFromBeginning() {}

  public func didStartPlaying() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
    nowPlayingInfoCenter.playbackState = .playing
  }

  public func didPause() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
    nowPlayingInfoCenter.playbackState = .paused
  }

  public func didStopPlaying() {
    nowPlayingInfoCenter.nowPlayingInfo = nil
    nowPlayingInfoCenter.playbackState = .stopped
  }

  public func didElapsedTimeChange() {
    // Patch 113 (step 1): elapsed-only update — no artwork decode / dict rebuild.
    updateElapsedTime()
  }

  public func didPlaylistChange() {}

  public func didArtworkChange() {}

  public func didNowPlayingInfoChange() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
  }

  public func didShuffleChange() {}

  public func didRepeatChange() {}

  public func didPlaybackRateChange() {}
}
