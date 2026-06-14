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

// MARK: - AlbumCarouselTableCell

/// A table-cell adapter that hosts a horizontal album carousel using the
/// shared `AlbumCarousel.makeShelfSection` layout + `AlbumCollectionCell`.
/// Used by ArtistDetailVC for the artist's albums.
final class AlbumCarouselTableCell: UITableViewCell, UICollectionViewDataSource,
  UICollectionViewDelegate {
  static let reuseIdentifier = "AlbumCarouselTableCell"
  private static let cellReuseIdentifier = "AlbumCollectionCell"

  private var albums: [Album] = []
  private var onSelect: ((Album) -> ())?

  private lazy var collectionView: UICollectionView = {
    let layout = UICollectionViewCompositionalLayout(section: AlbumCarousel.makeShelfSection(
      contentInsets: NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16),
      includeHeader: false
    ))
    let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
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

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    contentView.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(albums: [Album], onSelect: @escaping (Album) -> ()) {
    self.albums = albums
    self.onSelect = onSelect
    collectionView.reloadData()
    collectionView.setContentOffset(.zero, animated: false)
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
    cell.display(container: albums[indexPath.item], itemWidth: AlbumCarousel.itemWidth)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard indexPath.item < albums.count else { return }
    onSelect?(albums[indexPath.item])
  }
}
