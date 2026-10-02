//
//  MPBuildingHideMode.swift
//  MapsIndoorsMapbox
//
//  Created by Aditya Singh Gaharwar on 23/09/2026.
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

/// How the Mapbox base map hides its own 3D buildings across the transition band.
///
/// * ``buildingsOpacity`` — a graded float, so buildings fade gradually. The live Standard style
///   honours it online.
/// * ``show3dObjects`` — Standard's binary umbrella toggle for all 3D objects, so a hard hide. This
///   is the offline fallback, because the cached Standard style does not honour `buildingsOpacity`.
/// * ``auto`` — the default: `buildingsOpacity` while online, `show3dObjects` while offline.
///
/// The raw values are not a wire format any more — a caller sets the case, not an integer. They are
/// still pinned by a test, because a host that persists the selection across launches will store the
/// raw value, and renumbering would silently reinterpret a saved choice.
@_spi(Private) public enum MPBuildingHideMode: Int, CaseIterable, Sendable {
    case auto = 0
    case buildingsOpacity = 1
    case show3dObjects = 2
}
