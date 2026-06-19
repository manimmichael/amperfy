//
//  LibraryFilter.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.2 (library view filtering).
//
//  Single source of truth for what the iOS library surfaces show. By default
//  the app is "on-phone-only": only music actually transferred to the device
//  (a DeviceOwnership row) is visible. The existing Server Mode toggle
//  (`cassetteServerModeEnabled`) flips this to the full Subsonic catalog.
//
//  The filter is consulted at fetch time (predicate composition), not at
//  render time, to avoid dim-then-show flicker.
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

// MARK: - LibraryFilter

/// Controls what tracks appear in library views based on ownership state.
public enum LibraryFilter {
  case onDeviceOnly // Default mode: only show owned tracks
  case everything // Server Mode: show the full Subsonic library
  // Reserved for future hybrid modes (e.g. "on device + downloadable").
}

// MARK: - LibraryFilterProvider

public protocol LibraryFilterProvider {
  var currentFilter: LibraryFilter { get }
}

// MARK: - CassetteLibraryFilterProvider

public final class CassetteLibraryFilterProvider: LibraryFilterProvider, Sendable {
  public static let shared = CassetteLibraryFilterProvider()

  /// Posted whenever the Server Mode toggle flips, so library views can
  /// recreate their fetched-results controllers with the new predicate.
  public static let filterChangedNotification = Notification.Name("CassetteLibraryFilterChanged")

  private let serverModeKey = "cassetteServerModeEnabled"

  public init() {}

  public var currentFilter: LibraryFilter {
    let serverMode = UserDefaults.standard.bool(forKey: serverModeKey)
    return serverMode ? .everything : .onDeviceOnly
  }

  public var isOnDeviceOnly: Bool { currentFilter == .onDeviceOnly }
}

// MARK: - CassetteOwnershipNotifier

/// Coalesces device-ownership changes (a track downloaded or removed) into a
/// single, debounced `filterChangedNotification`, so the on-device-only library
/// views rebuild their fetched-results controllers and re-snapshot the owned
/// set right after an add/remove — instead of going stale until the Server Mode
/// toggle or an app relaunch. A 50-track album records 50 times; debouncing
/// collapses that burst into one rebuild. Reuses filterChangedNotification
/// because its observers already do exactly the right thing (rebuild the FRC).
@MainActor
public final class CassetteOwnershipNotifier {
  public static let shared = CassetteOwnershipNotifier()

  private var pending: DispatchWorkItem?
  private let debounceInterval: TimeInterval = 0.4

  private init() {}

  /// Call after any DeviceOwnership add (record) or remove. Safe to call in a
  /// tight loop — only the last call within the debounce window fires.
  public func ownershipDidChange() {
    pending?.cancel()
    let work = DispatchWorkItem {
      NotificationCenter.default.post(
        name: CassetteLibraryFilterProvider.filterChangedNotification,
        object: nil
      )
    }
    pending = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + debounceInterval,
      execute: work
    )
  }
}
