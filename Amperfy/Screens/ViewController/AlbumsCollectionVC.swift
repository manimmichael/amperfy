//
//  AlbumsCollectionVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.06.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

// MARK: - AlbumsCollectionDiffableDataSource

class AlbumsCollectionDiffableDataSource: BasicUICollectionViewDiffableDataSource {
  /// Weak: the grid owns this data source, and a strong pointer back kept every grid alive
  /// after it left the screen.
  weak var vc: AlbumsCollectionVC?
  private var common: AlbumsCommonVCInteractions? { vc?.common }

  /// phone-taste: the letter of each section while the grid files albums by letter ("#"
  /// first, then the letters that have albums). Set with each snapshot, before it is
  /// applied. Empty for every other layout.
  var letters = [String]()
  /// Tiles in the applied snapshot, after duplicates are dropped: the count line's number.
  var itemCount = 0

  init(
    vc: AlbumsCollectionVC,
    collectionView: UICollectionView,
    cellProvider: @escaping UICollectionViewDiffableDataSource<Int, NSManagedObjectID>.CellProvider
  ) {
    self.vc = vc
    super.init(collectionView: collectionView, cellProvider: cellProvider)
  }

  func getAlbum(at indexPath: IndexPath) -> Album? {
    guard let objectID = itemIdentifier(for: indexPath) else { return nil }
    guard let object = try? appDelegate.storage.main.context.existingObject(with: objectID),
          let albumMO = object as? AlbumMO
    else {
      return nil
    }
    return Album(managedObject: albumMO)
  }

  func getFirstAlbum(in section: Int) -> Album? {
    getAlbum(at: IndexPath(row: 0, section: section))
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    canMoveItemAt indexPath: IndexPath
  )
    -> Bool {
    // reordering/moving is not allowed
    false
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  )
    -> UICollectionReusableView {
    guard kind == UICollectionView.elementKindSectionHeader else {
      return UICollectionReusableView()
    }
    let sectionHeader: CommonCollectionSectionHeader = collectionView
      .dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: CommonCollectionSectionHeader.typeName,
        for: indexPath
      ) as! CommonCollectionSectionHeader
    // cassette Polish 2 (B2): no Play/Shuffle header on the Albums grid listing.
    configure(header: sectionHeader, section: indexPath.section, in: collectionView)
    return sectionHeader
  }

  /// Fills a section header: its letter (or sort title) and, above the first one, the
  /// count line, both starting at the grid's own left inset. Also used to refresh headers
  /// already on screen when the albums change.
  func configure(
    header: CommonCollectionSectionHeader,
    section: Int,
    in collectionView: UICollectionView
  ) {
    header.display(
      title: headerTitle(for: section),
      count: countLine(for: section),
      leadingInset: AlbumsCollectionVC.sideInset(collectionView)
    )
  }

  /// The mono count line over the first section ("139 albums"): the All filter only, and
  /// none for an empty grid.
  func countLine(for section: Int) -> String? {
    guard section == 0, vc?.displayFilter == .all, itemCount > 0 else { return nil }
    return itemCount == 1 ? "1 album" : "\(itemCount) albums"
  }

  /// Whether a section header carries a title. Cheap, for header sizing.
  func showsHeaderTitle(in section: Int) -> Bool {
    guard let common else { return false }
    if common.isLetterResectioned { return section < letters.count }
    // cassette: adaptive grouping. When flattened, show no section title.
    guard common.isGroupedInAlphabeticSections else { return false }
    switch common.sortType {
    case .artist, .name, .rating, .year: return true
    case .duration, .newest, .recent: return false
    }
  }

  func headerTitle(for section: Int) -> String? {
    guard showsHeaderTitle(in: section), let common else { return nil }
    if common.isLetterResectioned { return letters[section] }
    switch common.sortType {
    case .artist, .name:
      return sectionTitleToIndexTitle(sectionName: sectionTitle(for: section))
    case .rating, .year:
      return sectionTitle(for: section)
    case .duration, .newest, .recent:
      return nil
    }
  }

  /// Whether the A to Z index shows down the right edge: a grid filed by letter with at
  /// least two letters, or a grouped Rating / Artist / Year / Duration sort. Never for a
  /// flat grid, where it would be one lone letter.
  var isIndexShown: Bool {
    guard let vc, !vc.isIndexTitelsHidden else { return false }
    let common = vc.common
    if common.isLetterResectioned { return letters.count >= 2 }
    switch common.sortType {
    case .artist, .duration, .name, .rating, .year:
      return common.isGroupedInAlphabeticSections
    case .newest, .recent:
      return false
    }
  }

  override func indexTitles(for collectionView: UICollectionView) -> [String]? {
    guard isIndexShown else { return nil }
    // phone-taste: the whole alphabet, steady, whatever letters the library has.
    if common?.isLetterResectioned == true { return String.libraryLetters }
    let sectionCount = numberOfSections(in: collectionView)
    var indexTitles = [String]()
    for i in 0 ..< sectionCount {
      let sectionName = sectionTitle(for: i)
      indexTitles.append(sectionTitleToIndexTitle(sectionName: sectionName))
    }
    return indexTitles
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    indexPathForIndexTitle title: String,
    at index: Int
  )
    -> IndexPath {
    guard common?.isLetterResectioned == true, !letters.isEmpty else {
      return super.collectionView(collectionView, indexPathForIndexTitle: title, at: index)
    }
    // A letter with no albums jumps to the next letter that has some, else the last one.
    let order = String.libraryLetters
    let tapped = order.firstIndex(of: title) ?? index
    let section = letters.firstIndex { (order.firstIndex(of: $0) ?? 0) >= tapped }
      ?? letters.count - 1
    return IndexPath(item: 0, section: section)
  }

  func sectionTitleToIndexTitle(sectionName: String) -> String {
    guard let sortType = common?.sortType else { return "" }
    var indexTitle = ""
    switch sortType {
    case .name:
      indexTitle = sectionName.prefix(1).uppercased()
      if let _ = Int(indexTitle) {
        indexTitle = "#"
      }
    case .artist:
      indexTitle = sectionName.prefix(1).uppercased()
      if let _ = Int(indexTitle) {
        indexTitle = "#"
      }
    case .rating:
      indexTitle = IndexHeaderNameGenerator.sortByRating(forSectionName: sectionName)
    case .duration:
      indexTitle = IndexHeaderNameGenerator.sortByDurationAlbum(forSectionName: sectionName)
    case .year:
      indexTitle = IndexHeaderNameGenerator.sortByYear(forSectionName: sectionName)
    default:
      break
    }
    return indexTitle
  }

  func sectionTitle(for section: Int) -> String {
    guard let sortType = common?.sortType else { return "" }
    switch sortType {
    case .name:
      guard let album = getFirstAlbum(in: section) else { return "" }
      return album.name
    case .rating:
      guard let album = getFirstAlbum(in: section) else { return "" }
      if album.rating > 0 {
        return "\(album.rating) Star\(album.rating != 1 ? "s" : "")"
      } else {
        return "Not rated"
      }
    case .newest, .recent:
      return ""
    case .artist:
      guard let album = getFirstAlbum(in: section) else { return "" }
      return album.subtitle ?? ""
    case .duration:
      guard let album = getFirstAlbum(in: section) else { return "" }
      return album.duration.description
    case .year:
      let year = getFirstAlbum(in: section)?.year.description
      guard let year = year else { return "" }
      return IndexHeaderNameGenerator.sortByYear(forSectionName: year)
    }
  }
}

// MARK: - AlbumsCollectionVC

class AlbumsCollectionVC: SingleSnapshotFetchedResultsCollectionViewController<AlbumMO> {
  override var sceneTitle: String? {
    common.sceneTitle
  }

  fileprivate var common: AlbumsCommonVCInteractions

  private var previousSize: CGSize = .zero
  /// Whether the index showed for the last applied snapshot, to reload when it comes or goes.
  private var wasIndexShown: Bool?
  /// Music arrived on or left the phone while the grid was off screen (or it was taken
  /// off screen): make the fetch again when it next appears.
  private var needsOwnedScopeRefresh = false
  /// The grid let go of its fetch when it was taken off screen (see didMove(toParent:)).
  private var isDetachedFromFetch = false

  public var displayFilter: DisplayCategoryFilter {
    set { common.displayFilter = newValue }
    get { common.displayFilter }
  }

  private var albumsDataSource: AlbumsCollectionDiffableDataSource? {
    diffableDataSource as? AlbumsCollectionDiffableDataSource
  }

  override init(collectionViewLayout: UICollectionViewLayout, account: Account) {
    self.common = AlbumsCommonVCInteractions(account: account)
    super.init(collectionViewLayout: collectionViewLayout, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUICollectionViewDiffableDataSource {
    let source = AlbumsCollectionDiffableDataSource(
      vc: self,
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, objectID -> UICollectionViewCell? in
      // The grid owns the collection view, so it is always here while cells are asked for.
      guard let self else { return nil }
      guard let object = try? self.appDelegate.storage.main.context.existingObject(with: objectID),
            let albumMO = object as? AlbumMO
      else {
        fatalError("Managed object should be available")
      }
      let album = Album(managedObject: albumMO)
      return self.createCell(collectionView, forItemAt: indexPath, album: album)
    }
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    suppressDuplicateLibraryEntityIds = true
    // ensures that the collection view stops placing items under the sidebar
    collectionView.contentInsetAdjustmentBehavior = .always

    appDelegate.userStatistics.visited(.albums)

    // phone-taste: every callback holds the grid weakly, so a grid that has left the
    // screen can be freed (see didMove(toParent:)).
    common.rootVC = self
    common.isIndexTitelsHiddenCB = { [weak self] in
      guard let self else { return }
      self.isIndexTitelsHidden = self.common.isIndexTitelsHidden
    }
    common.reloadListViewCB = { [weak self] in
      self?.collectionView.reloadData()
    }
    common.updateSearchResultsCB = { [weak self] in
      guard let self else { return }
      self.updateSearchResults(for: self.searchController)
    }
    common.endRefreshCB = { [weak self] in
      self?.refreshControl?.endRefreshing()
    }
    common.updateFetchDataSourceCB = { [weak self] in
      guard let self else { return }
      self.common.fetchedResultsController.delegate = self
    }
    // phone-taste: file a grouped Name sort into the mock's letters ("The Bends" under B),
    // computed here from the titles in memory. Set before the first fetch.
    common.isLetterResectioningEnabled = true
    snapshotTransform = { [weak self] snapshot, context in
      self?.librarySnapshot(from: snapshot, context: context) ?? snapshot
    }
    // The index down the right edge reads in ink2, never the accent.
    collectionView.tintColor = .cassette(.textSecondary)

    common.applyFilter()
    // cassette Polish 2 (B1): per-category search removed; use the global Search tab.
    collectionView.register(
      UINib(nibName: CommonCollectionSectionHeader.typeName, bundle: .main),
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: CommonCollectionSectionHeader.typeName
    )
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )

    switch common.sortType {
    case .artist, .duration, .name, .rating, .year:
      collectionView.showsVerticalScrollIndicator = false
    case .newest, .recent:
      collectionView.showsVerticalScrollIndicator = true
    }

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif

    refreshControl?.addTarget(
      common,
      action: #selector(AlbumsCommonVCInteractions.handleRefresh),
      for: UIControl.Event.valueChanged
    )
    collectionView.refreshControl = refreshControl

    containableAtIndexPathCallback = { [weak self] indexPath in
      self?.albumsDataSource?.getAlbum(at: indexPath)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let album = self?.albumsDataSource?.getAlbum(at: indexPath) else { return nil }
      return PlayContext(containable: album)
    }
    snapshotDidChange = { [weak self] in
      guard let self else { return }
      self.common.updateContentUnavailable()
      self.refreshVisibleSectionHeaders()
      self.reloadIfIndexVisibilityChanged()
    }

    // phone-taste: a phone shows only what is on it. When music arrives on or leaves the
    // phone (or Server Mode flips), make the fetch again with the new set of albums.
    // Posted on the main queue, debounced (CassetteOwnershipNotifier).
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(onPhoneLibraryChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )
  }

  @objc
  private func onPhoneLibraryChanged() {
    // Only a grid on screen fetches again straight away. One off screen (another tab,
    // under a pushed page, or closed) waits until it next appears, so a transfer never
    // makes hidden grids redo their whole fetch for every song that lands.
    guard viewIfLoaded?.window != nil else {
      needsOwnedScopeRefresh = true
      return
    }
    refreshOwnedScope()
  }

  private func refreshOwnedScope() {
    needsOwnedScopeRefresh = false
    isDetachedFromFetch = false // the new fetch takes the grid as its delegate
    // The grid diffs from the old albums to the new ones and keeps its place. Only a flip
    // between grouped and flat changes header sizes, which needs a reload.
    if common.refreshOwnedScope() {
      collectionView.reloadData()
    }
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    if parent == nil {
      // Taken off screen for good (a category or style switch, or popped). The fetch holds
      // its delegate strongly, which kept every closed grid alive and still working on
      // each library change. Let go of it so the grid can be freed. Should the grid be
      // shown again, it makes the fetch afresh when it appears.
      common.fetchedResultsController?.delegate = nil
      isDetachedFromFetch = true
      needsOwnedScopeRefresh = true
    } else if isDetachedFromFetch {
      // Moved to a new parent instead (a split view collapsing on iPad or Mac): listen to
      // the fetch again straight away, in case no appearance follows.
      isDetachedFromFetch = false
      common.fetchedResultsController?.delegate = self
    }
  }

  /// phone-taste: the mock's Library order (data.ts libraryOf). For the Name sort the
  /// fetched albums are sorted by `librarySortKey` and, while grouped, filed under their
  /// `libraryLetter` with "#" first, in a snapshot built fresh: only the item ids are read,
  /// never the fetch's section ids. Titles come from the albums already in memory; nothing
  /// stored is read or written. Every other sort keeps the fetch's own sections.
  private func librarySnapshot(
    from snapshot: NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>,
    context: NSManagedObjectContext
  )
    -> NSDiffableDataSourceSnapshot<Int, NSManagedObjectID> {
    let dataSource = albumsDataSource
    guard common.isLetterResectioningEnabled, common.sortType == .name else {
      dataSource?.letters = []
      dataSource?.itemCount = snapshot.numberOfItems
      return snapshot
    }
    let keyed: [(id: NSManagedObjectID, key: String)] = snapshot.itemIdentifiers.map { id in
      let albumMO = (try? context.existingObject(with: id)) as? AlbumMO
      let name = albumMO.map { Album(managedObject: $0).name } ?? ""
      return (id: id, key: name.librarySortKey)
    }
    let sorted = keyed.sorted { lhs, rhs in
      switch lhs.key.localizedStandardCompare(rhs.key) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame:
        // Same key: a steady order, so equal titles never trade places between updates.
        return lhs.id.uriRepresentation().absoluteString < rhs.id.uriRepresentation()
          .absoluteString
      }
    }

    var result = NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>()
    var letters = [String]()
    if common.isLetterResectioned {
      var buckets = [String: [NSManagedObjectID]]()
      for album in sorted {
        buckets[String.libraryLetter(forSortKey: album.key), default: []].append(album.id)
      }
      letters = String.libraryLetters.filter { buckets[$0] != nil }
      for letter in letters {
        // A letter keeps one section id ("#" 0, A 1 ... Z 26), so a letter that comes or
        // goes moves the sections after it instead of relabelling them.
        let section = Self.sectionIdentifier(forLetter: letter)
        result.appendSections([section])
        result.appendItems(buckets[letter] ?? [], toSection: section)
      }
    } else if !sorted.isEmpty {
      result.appendSections([0])
      result.appendItems(sorted.map { $0.id }, toSection: 0)
    }
    dataSource?.letters = letters
    dataSource?.itemCount = result.numberOfItems
    return result
  }

  private static func sectionIdentifier(forLetter letter: String) -> Int {
    String.libraryLetters.firstIndex(of: letter) ?? 0
  }

  /// Headers on screen are not dequeued again when the albums change, so repaint their
  /// letter and count line in place (a new letter can shift which section sits first).
  private func refreshVisibleSectionHeaders() {
    guard let albumsDataSource else { return }
    let kind = UICollectionView.elementKindSectionHeader
    for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
      guard let header = collectionView.supplementaryView(
        forElementKind: kind,
        at: indexPath
      ) as? CommonCollectionSectionHeader else { continue }
      albumsDataSource.configure(header: header, section: indexPath.section, in: collectionView)
    }
  }

  /// The index and the right gutter it needs come and go with the second letter. Reload
  /// then, so the index bar and the tile widths follow.
  private func reloadIfIndexVisibilityChanged() {
    let isIndexShown = albumsDataSource?.isIndexShown ?? false
    defer { wasIndexShown = isIndexShown }
    guard let wasIndexShown, wasIndexShown != isIndexShown else { return }
    collectionView.reloadData()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    if needsOwnedScopeRefresh { refreshOwnedScope() }
    extendSafeAreaToAccountForMiniPlayer()
    common.updateRightBarButtonItems()
    common.updateFromRemote()
    common.updateContentUnavailable()
  }

  func createCell(
    _ collectionView: UICollectionView,
    forItemAt indexPath: IndexPath,
    album: Album
  )
    -> UICollectionViewCell {
    let cell: AlbumCollectionCell = collectionView.dequeueReusableCell(
      withReuseIdentifier: AlbumCollectionCell.typeName,
      for: indexPath
    ) as! AlbumCollectionCell
    if let album = (diffableDataSource as? AlbumsCollectionDiffableDataSource)?
      .getAlbum(at: indexPath) {
      // phone-taste: the Library grid's smaller tile type, on the phone.
      cell.isCompact = Self.isPhoneGrid(collectionView)
      cell.display(
        container: album,
        rootView: self,
        rootFlowLayout: self,
        initialIndexPath: indexPath
      )
    }
    return cell
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let albumsDataSource = albumsDataSource,
          let album = albumsDataSource.getAlbum(at: indexPath)
    else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    common.listViewWillDisplayCell(at: indexPath, searchBarText: searchController.searchBar.text)
  }

  override func updateSearchResults(for searchController: UISearchController) {
    common.updateSearchResults(for: searchController)
    collectionView.reloadData()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    // Recalculate the layout when the viewController is resized
    let currentSize = view.bounds.size
    if currentSize != previousSize {
      previousSize = currentSize
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }
}

// MARK: UICollectionViewDelegateFlowLayout

extension AlbumsCollectionVC: UICollectionViewDelegateFlowLayout {
  static let minimumLineSpacing: CGFloat = 16
  static let minimumInteritemSpacing: CGFloat = 16
  /// phone-taste `.grid` gap: 14 between rows, 10 between columns (phone).
  static let phoneLineSpacing: CGFloat = 14
  static let phoneInteritemSpacing: CGFloat = 10
  /// phone-taste `.libSection` padding: 20 on the left, 34 on the right while the index
  /// shows (it sits in that gutter), else 20.
  static let phoneSideInset: CGFloat = 20
  static let phoneIndexedTrailingInset: CGFloat = 34
  /// iPad and Mac keep their left inset.
  static let regularSideInset: CGFloat = 16

  static func isPhoneGrid(_ collectionView: UICollectionView) -> Bool {
    collectionView.traitCollection.userInterfaceIdiom == .phone
  }

  /// The grid's left inset, which the section headers share so the letters and the count
  /// line sit over the first column: 20 on the phone, 16 on iPad and Mac.
  static func sideInset(_ collectionView: UICollectionView) -> CGFloat {
    isPhoneGrid(collectionView) ? phoneSideInset : regularSideInset
  }

  private func lineSpacing(_ collectionView: UICollectionView) -> CGFloat {
    Self.isPhoneGrid(collectionView) ? Self.phoneLineSpacing : Self.minimumLineSpacing
  }

  private func interitemSpacing(_ collectionView: UICollectionView) -> CGFloat {
    Self.isPhoneGrid(collectionView) ? Self.phoneInteritemSpacing : Self.minimumInteritemSpacing
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  )
    -> CGSize {
    let inset = self.collectionView(
      collectionView,
      layout: collectionViewLayout,
      insetForSectionAt: indexPath.section
    )

    let marginsAndInsets = inset.left + inset.right + collectionView.safeAreaInsets
      .left + collectionView.safeAreaInsets.right + interitemSpacing(collectionView) *
      CGFloat(appDelegate.storage.settings.user.albumsGridSizeSetting - 1)
    let itemWidth =
      (
        (collectionView.bounds.size.width - marginsAndInsets) /
          CGFloat(appDelegate.storage.settings.user.albumsGridSizeSetting)
      ).rounded(.down)
    // The tile is its square cover plus the text under it: the compact phone block
    // (measured from the fonts, see AlbumCollectionCell) or the regular one.
    let textBlockHeight = Self.isPhoneGrid(collectionView) ?
      AlbumCollectionCell.compactTextBlockHeight : 45
    return CGSize(width: itemWidth, height: itemWidth + textBlockHeight)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumLineSpacingForSectionAt section: Int
  )
    -> CGFloat {
    lineSpacing(collectionView)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumInteritemSpacingForSectionAt section: Int
  )
    -> CGFloat {
    interitemSpacing(collectionView)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    insetForSectionAt section: Int
  )
    -> UIEdgeInsets {
    let left = Self.sideInset(collectionView)
    if Self.isPhoneGrid(collectionView) {
      // The header above each section carries the spacing. A section without one (the
      // Duration sort, Newest, Recent) keeps a row gap above it.
      let top = headerHeight(for: section) > 0 ? 0 : Self.phoneLineSpacing
      let trailing = (albumsDataSource?.isIndexShown ?? false) ?
        Self.phoneIndexedTrailingInset : Self.phoneSideInset
      return UIEdgeInsets(top: top, left: left, bottom: 0, right: trailing)
    } else {
      return UIEdgeInsets(top: 8, left: left, bottom: 8, right: 32)
    }
  }

  /// The header above `section`: the count line over the first section, then the letter
  /// (or the sort's title). Zero when it would be empty.
  private func headerHeight(for section: Int) -> CGFloat {
    guard let albumsDataSource else { return 0 }
    return CommonCollectionSectionHeader.height(
      showsCount: albumsDataSource.countLine(for: section) != nil,
      showsTitle: albumsDataSource.showsHeaderTitle(in: section)
    )
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  )
    -> CGSize {
    // cassette Polish 2 (B2): no Play/Shuffle header. phone-taste: section 0 carries the
    // count line; a flat grid shows the count line alone, never a lone letter.
    CGSize(width: collectionView.bounds.size.width, height: headerHeight(for: section))
  }
}
