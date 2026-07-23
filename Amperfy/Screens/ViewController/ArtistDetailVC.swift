//
//  ArtistDetailVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import CoreData
import UIKit

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }

  /// cassette: artist detail body — "Albums" now LEADS (this is the owned-
  /// library artist view; albums are what the user owns and came here for), and
  /// "Popular" (songs by play count) is the demoted secondary section below it.
  /// Section 0 stays the empty spacer the legacy layout needs (see
  /// numberOfSections). FLAG: a single ArtistDetailVC serves BOTH the owned-
  /// library and (in Server Mode) the broader-catalog artist context — there is
  /// no distinct discovery screen — so per the brief the owned-library order
  /// (albums-first) is applied to this shared view.
  private enum BodySection: Int {
    case spacer = 0
    case albums = 1
    case popular = 2
  }

  private var artist: Artist
  var albumToScrollTo: Album?
  private var albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController!
  private var songsFetchedResultsController: ArtistSongsItemsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var collapsedPlayButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  private let stickyHeader = DetailStickyHeaderView()

  /// Patch 110 (3a): the Popular list is capped to the top
  /// `popularCollapsedLimit` tracks (ranked by play count — `sortByPlayCount`
  /// is already wired below) with a trailing "Show more" row that expands to
  /// the full list. Ranking reflects device-local play history; when sparse it
  /// falls back to the FRC's secondary track order.
  private static let popularCollapsedLimit = 5
  private var isPopularExpanded = false

  /// cassette: the Popular list is ranked by play count, and countPlayed bumps
  /// it on every play — which live-reorders the FRC and shuffles the list under
  /// the user. So the ranked order is SNAPSHOTTED on viewWillAppear and rendered
  /// in that fixed order for the lifetime of the presentation; it re-ranks only
  /// on the next appearance, never live. The now-playing row indicator stays
  /// live (it's the cell's own state, keyed off the current track) — only the
  /// row ORDER is frozen.
  private var frozenPopularSongs: [Song] = []

  private func frozenPopularSong(at row: Int) -> Song? {
    guard row >= 0, row < frozenPopularSongs.count else { return nil }
    return frozenPopularSongs[row]
  }

  /// Re-snapshot the FRC's current ranked order. Called on each viewWillAppear.
  private func freezePopularOrder() {
    let count = songsFetchedResultsController?.sections?[0].numberOfObjects ?? 0
    frozenPopularSongs = (0 ..< count).compactMap {
      songsFetchedResultsController?.getWrappedEntity(at: IndexPath(row: $0, section: 0))
    }
    if isViewLoaded, tableView.numberOfSections > BodySection.popular.rawValue {
      tableView.reloadSections(IndexSet(integer: BodySection.popular.rawValue), with: .none)
    }
  }

  private var popularTotalCount: Int {
    frozenPopularSongs.count
  }

  private var popularRowsShown: Int {
    isPopularExpanded ? popularTotalCount : min(popularTotalCount, Self.popularCollapsedLimit)
  }

  private var showsPopularShowMore: Bool {
    !isPopularExpanded && popularTotalCount > Self.popularCollapsedLimit
  }

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    // cassette Patch 037: pin inline title for this VC before super
    // runs so the nav bar collapses the parent's large title in the
    // first frame of the push transition — otherwise "Artists"
    // briefly renders behind the detail title.
    navigationItem.largeTitleDisplayMode = .never
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)

    // cassette Patch 103 (Phase 3.3): re-resolve to the relationship-rich same-id
    // artist before building the FRCs. Prevents the empty-detail bug when this VC
    // is entered with a metadata-only stub (album link, search, Home shelf) whose
    // identity-bound FRCs (song.artist == self) would otherwise return nothing.
    artist = appDelegate.storage.main.library.richestSameIdArtist(for: artist, account: account)

    // cassette redesign (Surface 1): overflow returns to the navigation bar
    // (native glass circle on iOS 26); a play bar-button joins it when the
    // hero collapses under the bar.
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: artist, on: self).createMenuActions()
    }
    collapsedPlayButton = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        let songs = songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
        appDelegate.player.play(context: PlayContext(
          containable: artist,
          playables: songs.filterSongs().sortByAlbum()
        ))
      }
    )
    collapsedPlayButton.accessibilityLabel = "Play"

    albumsFetchedResultsController = ArtistAlbumsItemsFetchedResultsController(
      for: artist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    albumsFetchedResultsController.delegate = self
    songsFetchedResultsController = ArtistSongsItemsFetchedResultsController(
      for: artist,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false,
      sortByPlayCount: true
    )
    songsFetchedResultsController.delegate = self
    // cassette Patch 104: the named bug behind the empty artist body — the
    // FRCs were created but never fetched. Patch 045 removed the in-view
    // search path whose showAllResults() used to do the fetching, so the
    // body rendered zero rows even though the data was there. Fetch both
    // explicitly.
    albumsFetchedResultsController.fetch()
    songsFetchedResultsController.fetch()
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    // Patch 110 (3b): the artist's albums render as a horizontal carousel
    // (one row hosting AlbumCarouselTableCell) instead of vertical list rows.
    tableView.register(
      AlbumCarouselTableCell.self,
      forCellReuseIdentifier: AlbumCarouselTableCell.reuseIdentifier
    )
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor
    // Patch 111 (1): no row separators. The only divider is the subtle line
    // between the top-level sections (Popular → Albums), drawn in the custom
    // Albums header (viewForHeaderInSection).
    tableView.separatorStyle = .none

    // cassette Patch 104 (Root 2): artwork is the first content of the
    // scroll. The table extends under the navigation bar (insets mirrored
    // manually in viewDidLayoutSubviews) and the bar is transparent at the
    // scroll edge so back/overflow float over the artwork; the system
    // restores the standard bar surface once content scrolls under it.
    tableView.contentInsetAdjustmentBehavior = .never
    // Patch 109: every appearance slot starts transparent so the bar never
    // snaps to the opaque global standardAppearance the instant the user
    // scrolls. DetailStickyHeaderSupport.updateAlpha then fades the bar
    // background in lockstep with the title as the hero collapses.
    let transparentBar = UINavigationBarAppearance()
    transparentBar.configureWithTransparentBackground()
    navigationItem.standardAppearance = transparentBar
    navigationItem.compactAppearance = transparentBar
    navigationItem.scrollEdgeAppearance = transparentBar
    navigationItem.compactScrollEdgeAppearance = transparentBar
    // cassette Patch 108: iOS 26 adds an always-on soft top scroll-edge effect
    // (a dark gradient/scrim) over content that extends under the bar, which
    // darkens the top of the artwork at rest. Hide it so the artwork is clean
    // at rest; the opaque standardAppearance still supplies the solid bar
    // surface once content scrolls under it.
    if #available(iOS 26.0, *) {
      tableView.topEdgeEffect.isHidden = true
    }

    // cassette Patch 045: in-view search removed from artist detail.
    // Library category lists keep their search controllers; the
    // detail view shows the artist's full top-songs + albums set.
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.artist.albumCount) Album\(self.artist.albumCount == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(self.artist.songCount) Song\(self.artist.songCount == 1 ? "" : "s")"
      },
      playContextCb: { () in
        let songs = self.songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
        let sortedSongs = songs.filterSongs().sortByAlbum()
        return PlayContext(containable: self.artist, playables: sortedSongs)
      },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: artist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: true
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshArtistMetadataLine()
    DetailStickyHeaderSupport.install(
      stickyHeader: stickyHeader,
      in: self,
      overflowItem: optionsButton,
      collapsedPlayItem: collapsedPlayButton
    )
    refreshStickyHeaderText()
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }

    containableAtIndexPathCallback = { indexPath in
      switch BodySection(rawValue: indexPath.section) {
      case .albums:
        // Patch 110 (3b): albums are a single carousel row — no per-album swipe.
        return nil
      case .popular:
        guard indexPath.row < self.popularRowsShown else { return nil }
        return self.frozenPopularSong(at: indexPath.row)
      default:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      switch BodySection(rawValue: indexPath.section) {
      case .albums:
        // Patch 110 (3b): albums are a single carousel row — taps navigate via
        // the carousel's onSelect, not a play context.
        return nil
      case .popular:
        guard indexPath.row < self.popularRowsShown else { return nil }
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        return self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
      default:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      switch BodySection(rawValue: indexPath.section) {
      case .albums:
        // Patch 110 (3b): no swipe actions on the carousel row.
        completionHandler(nil)
      case .popular:
        guard indexPath.row < self.popularRowsShown,
              let song = self.frozenPopularSong(at: indexPath.row) else {
          completionHandler(nil)
          return
        }
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let playContext = self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
    // Snapshot the play-count ranking for this presentation so the list doesn't
    // reorder live as tracks are played; re-ranks on the next appearance.
    freezePopularOrder()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // cassette (header-pop fix, round 3): while popping, skip ALL of the
    // inset-driven re-layout — see AlbumDetailVC for the full rationale (the
    // safe-area-derived insets shift as the bar animates and re-expand the hero).
    guard !isHeaderTransitionFrozen else { return }
    // Patch 104 (Root 2): with contentInsetAdjustmentBehavior == .never the
    // safe areas are mirrored manually (bottom = tab bar + mini player).
    tableView.contentInset.bottom = view.safeAreaInsets.bottom
    tableView.verticalScrollIndicatorInsets.top = view.safeAreaInsets.top
    tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
    detailOperationsView?.resizeToFit()
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateStickyHeaderAlpha()
    (tabBarController as? TabBarVC)?.cassetteUpdateMinimizeForScroll(scrollView)
  }

  // resizeToFit defers any header re-measure that arrives mid-scroll (it would
  // flash the collapsed title — see GenericDetailTableHeader.resizeToFit). Land
  // the deferred size once the scroll settles.
  // NOTE: no super call here — ArtistDetailVC's super chain goes through
  // MultiSourceTableViewController → BasicTableViewController →
  // KeyCommandTableViewController → UITableViewController, none of which
  // implement scrollViewDidEnd*. The chain for AlbumDetailVC is different
  // (it goes through BasicFetchedResultsTableViewController which does).
  // Calling super from here would crash with "unrecognized selector".
  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    detailOperationsView?.resizeToFit()
  }

  override func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    if !decelerate {
      detailOperationsView?.resizeToFit()
    }
  }

  private func updateStickyHeaderAlpha() {
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: tableView,
      tableHeaderView: tableView.tableHeaderView,
      in: self,
      collapsedPlayItem: collapsedPlayButton
    )
  }

  private func refreshStickyHeaderText() {
    var parts = ["Artist"]
    if artist.albumCount > 0 {
      parts.append("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
    }
    if artist.songCount > 0 {
      parts.append("\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")")
    }
    let subtitle = parts.count > 1 ? parts.joined(separator: " · ") : nil
    stickyHeader.configure(title: artist.name, subtitle: subtitle)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    // Restore the correct alpha when popping back to a scrolled screen —
    // viewWillDisappear resets alpha to 0 for the push transition.
    updateStickyHeaderAlpha()
    albumsFetchedResultsController?.delegate = self
    songsFetchedResultsController?.delegate = self
    Task { @MainActor in
      do {
        try await artist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Artist Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshArtistMetadataLine()
      self.detailOperationsView?.refresh()
    }
  }

  // Patch 026: artist metadata line. Year doesn't apply, so we surface
  // catalog scope instead: "12 albums · 187 songs". Counts are suppressed
  // when missing rather than rendered as zeros.
  //
  // cassette: the leading type noun is gone across every detail page. It
  // only ever told you which page you were already looking at.
  private func refreshArtistMetadataLine() {
    var parts: [String] = []
    if artist.albumCount > 0 {
      parts.append("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
    }
    if artist.songCount > 0 {
      parts.append("\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
    refreshStickyHeaderText()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Reset the collapsed title only when PUSHING a child (this VC stays in the
    // stack, so the child's bar starts clean). On a POP — including the
    // interactive edge-swipe — `isMovingFromParent` is true; zeroing alpha here
    // would snap the bar title off mid-swipe ("header re-expands"). Leave it so
    // the title slides away continuously with the content. A cancelled swipe
    // self-heals: viewIsAppearing recomputes alpha from the scroll offset.
    if !isMovingFromParent {
      stickyHeader.alpha = 0
    } else {
      // cassette (header-pop fix, round 3): freeze the collapsing header for the
      // whole pop so it rides off-screen instead of re-expanding.
      freezeCollapsingHeaderForPopTransition { [weak self] in
        guard let self else { return }
        // On a cancelled swipe, resume normal scroll-driven layout/alpha.
        detailOperationsView?.resizeToFit()
        updateStickyHeaderAlpha()
      }
    }
    albumsFetchedResultsController?.delegate = nil
    songsFetchedResultsController?.delegate = nil
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { albumToScrollTo = nil }
    // Patch 110 (3b): albums live in one carousel row — scroll that row into
    // view (the per-album scroll target no longer maps to a table row).
    guard albumToScrollTo != nil,
          tableView.numberOfSections > BodySection.albums.rawValue,
          tableView.numberOfRows(inSection: BodySection.albums.rawValue) > 0
    else { return }
    tableView.scrollToRow(
      at: IndexPath(row: 0, section: BodySection.albums.rawValue),
      at: .top,
      animated: true
    )
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    // Play from the frozen popular order so the queue matches what's on screen.
    guard let selectedSong = frozenPopularSong(at: songIndexPath.row) else { return nil }
    let contextSongs = appDelegate.storage.settings.user.isOfflineMode
      ? frozenPopularSongs.filter { $0.isCached }
      : frozenPopularSongs
    guard let playContextIndex = contextSongs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: artist, index: playContextIndex, playables: contextSongs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          BodySection(rawValue: indexPath.section) == .popular
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 2 section + 1 top section. The top section is needed due to display bugs
    3
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch BodySection(rawValue: section) {
    case .albums:
      return "Albums"
    case .popular:
      return "Popular"
    default:
      return ""
    }
  }

  // Patch 111 (1/2): custom section headers — leading at the shared content
  // margin (16pt, matching rows and the album carousel). cassette: the
  // hairline divider that used to sit atop the Popular header was removed.
  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    // cassette: section headers are just the uppercased label now — no
    // dividers between the top-level sections.
    switch BodySection(rawValue: section) {
    case .albums:
      guard (albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0) > 0 else {
        return nil
      }
      return makeSectionHeaderView(title: "Albums")
    case .popular:
      guard popularTotalCount > 0 else { return nil }
      return makeSectionHeaderView(title: "Popular")
    default:
      return nil
    }
  }

  private func makeSectionHeaderView(title: String) -> UIView {
    let container = UIView()
    container.backgroundColor = .clear
    let label = UILabel()
    label.text = title.uppercased()
    label.font = UIFont.cassette(.caption)
    label.textColor = CassetteTheme.UIColors.ink2
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: container.leadingAnchor,
        constant: UIView.defaultMarginCellX
      ),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
    ])
    return container
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch BodySection(rawValue: section) {
    case .albums:
      // Patch 110 (3b): a single row hosting the horizontal album carousel.
      return (albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0) > 0 ? 1 : 0
    case .popular:
      return popularRowsShown + (showsPopularShowMore ? 1 : 0)
    default:
      return 0
    }
  }

  /// Patch 110 (3b): all of the artist's albums, in FRC order, for the carousel.
  private func allArtistAlbums() -> [Album] {
    let count = albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    return (0 ..< count).compactMap { albumsFetchedResultsController.getWrappedEntity(at: $0) }
  }

  private var albumsReloadScheduled = false
  /// Coalesce FRC album changes into a single reload of the carousel row.
  private func scheduleAlbumsReload() {
    guard !albumsReloadScheduled else { return }
    albumsReloadScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      albumsReloadScheduled = false
      guard tableView.numberOfSections > BodySection.albums.rawValue else { return }
      tableView.reloadSections(IndexSet(integer: BodySection.albums.rawValue), with: .none)
    }
  }

  /// Patch 110 (3a): centered "Show more" row that reveals the full Popular
  /// list. Quiet ink2 styling — orange stays reserved for live state.
  private func makePopularShowMoreCell() -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    var content = cell.defaultContentConfiguration()
    content.text = "Show more"
    content.textProperties.color = CassetteTheme.UIColors.ink2
    content.textProperties.font = UIFont.cassette(.rowTitle)
    content.textProperties.alignment = .center
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch BodySection(rawValue: indexPath.section) {
    case .albums:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: AlbumCarouselTableCell.reuseIdentifier,
        for: indexPath
      ) as! AlbumCarouselTableCell
      cell.configure(albums: allArtistAlbums()) { [weak self] album in
        guard let self else { return }
        navigationController?.pushViewController(
          AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
          animated: true
        )
      }
      return cell
    case .popular:
      if showsPopularShowMore, indexPath.row == popularRowsShown {
        return makePopularShowMoreCell()
      }
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      guard let song = frozenPopularSong(at: indexPath.row) else { return UITableViewCell() }
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch BodySection(rawValue: section) {
    case .albums:
      return albumsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case .popular:
      return popularTotalCount > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch BodySection(rawValue: indexPath.section) {
    case .albums:
      return AlbumCarousel.shelfHeight
    case .popular:
      if showsPopularShowMore, indexPath.row == popularRowsShown {
        return 48.0
      }
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch BodySection(rawValue: indexPath.section) {
    case .albums:
      return AlbumCarousel.shelfHeight
    case .popular:
      if showsPopularShowMore, indexPath.row == popularRowsShown {
        return 48.0
      }
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch BodySection(rawValue: indexPath.section) {
    case .albums:
      // Patch 110 (3b): the carousel cell handles album taps via its onSelect;
      // the table row itself is not selectable.
      break
    case .popular:
      // Patch 110 (3a): tap the trailing "Show more" row to reveal the full list.
      if showsPopularShowMore, indexPath.row == popularRowsShown {
        tableView.deselectRow(at: indexPath, animated: true)
        isPopularExpanded = true
        tableView.reloadSections(
          IndexSet(integer: BodySection.popular.rawValue),
          with: .fade
        )
      }
    default: break
    }
  }

  // cassette Patch 045: `updateSearchResults` override removed
  // alongside the search controller; the base no-op runs in its
  // place when a parent view fires `updateSearchResults(for:)`.

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    var section = 0
    switch controller {
    case albumsFetchedResultsController.fetchResultsController:
      // Patch 110 (3b): albums are one carousel row; the FRC's per-album
      // indices no longer map to table rows. Coalesce to a section reload so
      // the carousel rebuilds from the fresh album set.
      scheduleAlbumsReload()
      return
    case songsFetchedResultsController.fetchResultsController:
      // cassette: the Popular order is frozen for the presentation (see
      // frozenPopularSongs), so ignore live FRC reorders / play-count re-sorts
      // here — applying them would shuffle the list under the user. The order
      // re-ranks on the next appearance via freezePopularOrder(); the
      // now-playing indicator stays live through the cell's own player observer.
      return
    default:
      return
    }

    resultUpdateHandler?.applyChangesOfMultiRowType(
      controller,
      didChange: anObject,
      determinedSection: section,
      at: indexPath,
      for: type,
      newIndexPath: newIndexPath
    )
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange sectionInfo: NSFetchedResultsSectionInfo,
    atSectionIndex sectionIndex: Int,
    for type: NSFetchedResultsChangeType
  ) {}
}
