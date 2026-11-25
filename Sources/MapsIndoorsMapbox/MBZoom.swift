//
//  MBZoom.swift
//  MapsIndoorsMapbox
//
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

/// Converts between the two zoom scales in play: MapsIndoors zoom levels sit one level above Mapbox's.
/// Everything the SDK exposes, ``MPCameraPosition/zoom`` and ``MPCameraLimits`` included, is on the
/// MapsIndoors scale; everything handed to or read from `MapboxMap` is on Mapbox's.
enum MBZoom {
    private static let offset = 1.0

    static func mapsIndoors(fromMapbox zoom: Double) -> Double { zoom + offset }

    static func mapbox(fromMapsIndoors zoom: Double) -> Double { zoom - offset }
}
