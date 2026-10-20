//
//  ListScreenChrome.swift
//  Amperfy
//
//  Cassette: what every library list screen shares, wired once (design-system audit
//  2026-10-20, Wave 3). Both list bases, `BasicTableViewController` and
//  `BasicCollectionViewController`, adopt it, so a fix here lands on every list at once
//  instead of in whichever screen someone was looking at.
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

import AmperfyKit
import UIKit

// MARK: - ListEmptyState

/// What a list shows when it has nothing to show. Every list goes through
/// `applyEmptyState`, so empty screens share one look (the Cassette type from
/// `cassetteEmpty` / `cassetteNoResults`) and one rule for "searching".
struct ListEmptyState {
  /// The list is empty and nobody is searching.
  let empty: UIContentUnavailableConfiguration
  /// A typed search found nothing.
  var noResults: UIContentUnavailableConfiguration = .cassetteNoResults()
  /// Lists that follow the on-device library filter swap in the on-device copy ("No music
  /// on this phone yet") while only this phone's music is listed.
  var followsOnDeviceFilter = false

  @MainActor
  func configuration(isSearching: Bool) -> UIContentUnavailableConfiguration {
    if followsOnDeviceFilter, CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      return isSearching ? .cassetteOnDeviceNoResults : .cassetteOnDeviceEmpty
    }
    return isSearching ? noResults : empty
  }
}

extension UIViewController {
  /// Show `state` when the list is empty, nothing otherwise.
  func applyEmptyState(_ state: ListEmptyState, isEmpty: Bool, isSearching: Bool) {
    contentUnavailableConfiguration = isEmpty ? state.configuration(isSearching: isSearching) : nil
  }
}

// MARK: - ListScreenChrome

@MainActor
protocol ListScreenChrome: UIViewController {
  var searchController: UISearchController { get }
}

extension ListScreenChrome {
  /// Only a typed query counts as searching. The fetch controllers report an active search
  /// even for an empty query, which is how idle empty lists came to show "No results"
  /// (BUG-419; the fix had reached only Songs and Artists).
  var isUserSearching: Bool {
    !(searchController.searchBar.text ?? "").isEmpty
  }

  /// `applyEmptyState` with this list's own notion of searching.
  func applyEmptyState(_ state: ListEmptyState, isEmpty: Bool) {
    applyEmptyState(state, isEmpty: isEmpty, isSearching: isUserSearching)
  }
}

// MARK: - ListAppearanceRefresh

/// Decides when a list re-runs its search on appearing. It used to re-run on EVERY
/// appearance, a pop back from an album included: a full refetch and reload that snapped
/// the scroll position, flashed the empty state and reset the person's chosen scope
/// (BUG-428). The fetch controllers already keep a list current while it lives; what they
/// cannot see is a change of the owned-library set baked into their predicate (posted as
/// `filterChangedNotification`) or a change of offline mode. So the list refreshes on its
/// first appearance, after either of those, and never otherwise.
@MainActor
final class ListAppearanceRefresh {
  enum Decision {
    /// Nothing changed since the last refresh.
    case none
    /// Re-run the search, keeping the person's scope.
    case refresh
    /// First appearance or offline mode changed: reset the scope, then re-run the search.
    case resetScopeAndRefresh
  }

  private var refreshedForOfflineMode: Bool?
  private var isStale = false
  nonisolated(unsafe) private var filterObserver: NSObjectProtocol?

  init() {
    // Posted on the main queue (debounced) when the owned-library set or the Server Mode
    // filter changes; the predicate every library list baked at fetch time is now stale.
    filterObserver = NotificationCenter.default.addObserver(
      forName: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.isStale = true }
    }
  }

  deinit {
    if let filterObserver { NotificationCenter.default.removeObserver(filterObserver) }
  }

  /// Call on every `viewIsAppearing`.
  func decide(isOfflineMode: Bool) -> Decision {
    defer {
      refreshedForOfflineMode = isOfflineMode
      isStale = false
    }
    if refreshedForOfflineMode != isOfflineMode { return .resetScopeAndRefresh }
    return isStale ? .refresh : .none
  }
}
