//
//  HomeShelfEventMO+CoreDataProperties.swift
//  AmperfyKit
//
//  Cassette fork — Forgotten Albums shelf (hot-tier feedback log).
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

import CoreData
import Foundation

extension HomeShelfEventMO {
  @nonobjc
  public class func fetchRequest() -> NSFetchRequest<HomeShelfEventMO> {
    NSFetchRequest<HomeShelfEventMO>(entityName: "HomeShelfEvent")
  }

  // kind raw values — keep stable (persisted).
  public static let kindSurfaced: Int16 = 0
  public static let kindOpenedFromShelf: Int16 = 1

  @NSManaged
  public var albumId: String
  @NSManaged
  public var date: Date
  @NSManaged
  public var kind: Int16
}
