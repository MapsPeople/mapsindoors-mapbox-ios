//
//  MBCameraBoundsResolution.swift
//  MapsIndoorsMapbox
//
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import CoreGraphics
import MapsIndoors
@_spi(Private) import MapsIndoorsCore

/// The zoom and pitch ranges to hand `MapboxMap.setCameraBounds`, resolved from the map's own bounds, the
/// zoom the solution's modules license, and the app's ``MPCameraLimits``.
///
/// Pure, so the rules that decide which of the three wins are testable without a map. Zoom values are on
/// the Mapbox scale; ``MPCameraLimits`` arrives on the MapsIndoors scale.
struct MBCameraBoundsResolution: Equatable {
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let minPitch: CGFloat
    let maxPitch: CGFloat

    /// The licensed cap always wins over a higher ``MPCameraLimits/maxZoom``, and the resolved zoom range
    /// is always ordered, since Mapbox rejects an inverted one.
    static func resolve(
        baselineMinZoom: CGFloat,
        baselineMaxZoom: CGFloat,
        baselineMinPitch: CGFloat,
        baselineMaxPitch: CGFloat,
        licensedMaxZoom: CGFloat?,
        limits: MPCameraLimits?
    ) -> MBCameraBoundsResolution {
        let engineMax = licensedMaxZoom ?? baselineMaxZoom

        guard let limits else {
            return MBCameraBoundsResolution(minZoom: baselineMinZoom, maxZoom: engineMax, minPitch: baselineMinPitch, maxPitch: baselineMaxPitch)
        }

        let range = limits.zoomRange(
            engineMin: MBZoom.mapsIndoors(fromMapbox: Double(baselineMinZoom)),
            engineMax: MBZoom.mapsIndoors(fromMapbox: Double(engineMax)))
        let maxZoom = Swift.min(CGFloat(MBZoom.mapbox(fromMapsIndoors: range.max)), engineMax)
        let minZoom = Swift.min(CGFloat(MBZoom.mapbox(fromMapsIndoors: range.min)), maxZoom)
        let pitch = limits.fixedTiltDegrees(maxTilt: Double(baselineMaxPitch)).map { CGFloat($0) }

        return MBCameraBoundsResolution(minZoom: minZoom, maxZoom: maxZoom, minPitch: pitch ?? baselineMinPitch, maxPitch: pitch ?? baselineMaxPitch)
    }
}
