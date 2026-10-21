//
//  AlbumCarousel.swift
//  Amperfy
//
//  cassette Patch 110 (3b): the horizontal album shelf, extracted into ONE
//  reusable component with two callers:
//   - HomeVC's "Albums"/"Recent" shelves call `AlbumCarousel.makeShelfSection`
//     for their compositional-layout sections.
//   - ArtistDetailVC hosts `AlbumCarouselTableCell` (which builds its own
//     collection view from the same section factory) so the artist's albums
//     render as a carousel instead of vertical list rows.
//  Both reuse the shared `AlbumCollectionCell`.
//

import AmperfyKit
import UIKit

// MARK: - AlbumCarousel

enum AlbumCarousel {
  /// Card width — matches the Home shelf (was HomeVC.itemWidth).
  static let itemWidth: CGFloat = 160.0
  /// Estimated shelf height (artwork + title + subtitle) — matches Home.
  static let shelfHeight: CGFloat = 210.0
  /// The phone mocks' shelf tile width (`PlayTile`, 150px).
  static let mockItemWidth: CGFloat = 150
  /// The phone mocks' page gutter (20px), a shelf's side inset.
  static let mockGutter: CGFloat = 20

  /// The shared horizontal album-shelf compositional section: a continuous
  /// orthogonal-scrolling row of `itemWidth`-wide cards. `includeHeader` adds
  /// the boundary header supplementary the Home shelves use; the artist's
  /// embedded carousel sits under a normal table section header, so it passes
  /// `false`.
  static func makeShelfSection(
    itemWidth: CGFloat = AlbumCarousel.itemWidth,
    estimatedHeight: CGFloat = AlbumCarousel.shelfHeight,
    contentInsets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(
      top: 0,
      leading: 16,
      bottom: 24,
      trailing: 16
    ),
    interGroupSpacing: CGFloat = 12,
    includeHeader: Bool = false
  )
    -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .fractionalHeight(1.0)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .absolute(itemWidth),
      heightDimension: .estimated(estimatedHeight)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.orthogonalScrollingBehavior = .continuous
    section.interGroupSpacing = interGroupSpacing
    section.contentInsets = contentInsets
    section.supplementariesFollowContentInsets = false

    if includeHeader {
      let headerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(44)
      )
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: headerSize,
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top
      )
      header.pinToVisibleBounds = false
      header.zIndex = 1
      section.boundarySupplementaryItems = [header]
    }
    return section
  }
}

// MARK: - AlbumShelfStyle

/// The size and spacing of one album shelf. `.standard` is today's shelf; `.mock` and
/// `.mockLit` are the phone mocks' (150pt tiles in the 20pt gutter), the lit one with
/// clear tiles for a shelf drawn over a cover's glow.
struct AlbumShelfStyle: Equatable {
  var itemWidth: CGFloat = 160
  var sideInset: CGFloat = 16
  var spacing: CGFloat = 12
  var clearsTileBackground = false

  static let standard = AlbumShelfStyle()
  static let mock = AlbumShelfStyle(
    itemWidth: AlbumCarousel.mockItemWidth,
    sideInset: AlbumCarousel.mockGutter,
    spacing: 12
  )
  static let mockLit = AlbumShelfStyle(
    itemWidth: AlbumCarousel.mockItemWidth,
    sideInset: AlbumCarousel.mockGutter,
    spacing: 12,
    clearsTileBackground: true
  )
}

// MARK: - AlbumShelfView

/// One horizontal album shelf as a plain view, so it can sit anywhere: inside
/// `AlbumCarouselTableCell`, in a table footer, or in SwiftUI through a
/// UIViewRepresentable. Tapping a cover opens it (`onSelect`); with `onPlay`, each cover
/// also carries the one-tap play disc. Size it with `preferredHeight(for:)`.
final class AlbumShelfView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
  private static let cellReuseIdentifier = "AlbumCollectionCell"

  private var albums: [Album] = []
  private var onSelect: ((Album) -> ())?
  private var onPlay: ((Album) -> ())?
  private var subtitle: ((Album) -> String?)?
  private(set) var style = AlbumShelfStyle.standard
  /// The style the current compositional layout was built for.
  private var layoutStyle = AlbumShelfStyle.standard

  private lazy var collectionView: UICollectionView = {
    let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout(style: layoutStyle))
    cv.backgroundColor = .clear
    cv.showsHorizontalScrollIndicator = false
    cv.dataSource = self
    cv.delegate = self
    cv.register(
      UINib(nibName: Self.cellReuseIdentifier, bundle: nil),
      forCellWithReuseIdentifier: Self.cellReuseIdentifier
    )
    cv.translatesAutoresizingMaskIntoConstraints = false
    return cv
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setUp()
  }

  private func setUp() {
    backgroundColor = .clear
    addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  /// The shelf's height for a style: the tile (its width) plus the title and subtitle
  /// stack (41pt in AlbumCollectionCell.xib) and a little air.
  static func preferredHeight(for style: AlbumShelfStyle) -> CGFloat {
    style.itemWidth + 48
  }

  func configure(
    albums: [Album],
    onSelect: @escaping (Album) -> (),
    onPlay: ((Album) -> ())? = nil,
    style: AlbumShelfStyle = .standard,
    subtitle: ((Album) -> String?)? = nil
  ) {
    self.albums = albums
    self.onSelect = onSelect
    self.onPlay = onPlay
    self.subtitle = subtitle
    self.style = style
    if style != layoutStyle {
      // The layout is fixed at creation, so a new style needs a new layout.
      layoutStyle = style
      collectionView.setCollectionViewLayout(Self.makeLayout(style: style), animated: false)
    }
    collectionView.reloadData()
    collectionView.setContentOffset(.zero, animated: false)
  }

  private static func makeLayout(style: AlbumShelfStyle) -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout(section: AlbumCarousel.makeShelfSection(
      itemWidth: style.itemWidth,
      // Today's shelf keeps today's estimate; the mock styles use their own height.
      estimatedHeight: style == .standard ? AlbumCarousel.shelfHeight : preferredHeight(for: style),
      contentInsets: NSDirectionalEdgeInsets(
        top: 0,
        leading: style.sideInset,
        bottom: 0,
        trailing: style.sideInset
      ),
      interGroupSpacing: style.spacing,
      includeHeader: false
    ))
  }

  func collectionView(
    _ collectionView: UICollectionView,
    numberOfItemsInSection section: Int
  )
    -> Int {
    albums.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: Self.cellReuseIdentifier,
      for: indexPath
    ) as! AlbumCollectionCell
    let album = albums[indexPath.item]
    let onPlay = onPlay
    // Set before display(): the tile reads them while it binds.
    cell.subtitleOverride = subtitle?(album)
    cell.clearsBackground = style.clearsTileBackground
    cell.showsPlayOverlay = (onPlay != nil)
    cell.onPlayTapped = { onPlay?(album) }
    cell.display(container: album, itemWidth: style.itemWidth)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard indexPath.item < albums.count else { return }
    onSelect?(albums[indexPath.item])
  }
}

// MARK: - AlbumCarouselTableCell

/// A table cell hosting one `AlbumShelfView` (the artist page's albums, and the MORE BY /
/// MORE LIKE shelves on table pages).
final class AlbumCarouselTableCell: UITableViewCell {
  static let reuseIdentifier = "AlbumCarouselTableCell"

  let shelfView = AlbumShelfView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    shelfView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(shelfView)
    NSLayoutConstraint.activate([
      shelfView.topAnchor.constraint(equalTo: contentView.topAnchor),
      shelfView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      shelfView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      shelfView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// `onSelect` stays the first required closure, so a trailing closure still binds to it.
  /// `onPlay` turns on each cover's play disc (callers pass `OneTapPlay.play`).
  func configure(
    albums: [Album],
    onSelect: @escaping (Album) -> (),
    onPlay: ((Album) -> ())? = nil,
    style: AlbumShelfStyle = .standard,
    subtitle: ((Album) -> String?)? = nil
  ) {
    shelfView.configure(
      albums: albums,
      onSelect: onSelect,
      onPlay: onPlay,
      style: style,
      subtitle: subtitle
    )
  }
}
