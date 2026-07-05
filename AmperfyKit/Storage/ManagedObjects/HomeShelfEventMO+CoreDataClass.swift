//
//  HomeShelfEventMO+CoreDataClass.swift
//  AmperfyKit
//
//  Cassette fork — Forgotten Albums shelf (hot-tier feedback log).
//
//  A dated per-album shelf event (kind: surfaced / openedFromShelf). Hot tier:
//  30-day retention; aging rows are folded into AlbumMO's lifetime cold counters
//  (timesSurfacedLifetime / timesOpenedFromShelfLifetime) and then deleted.
//  Intentionally standalone — no Core Data relationships; joins to AlbumMO happen
//  via fetch-and-join on albumId (mirrors DeviceOwnershipMO). See
//  CASSETTE_BUG_REGISTER.md.
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

@objc(HomeShelfEventMO)
public class HomeShelfEventMO: NSManagedObject {}
