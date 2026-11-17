//
//  MBLandmarkVisibilityPolicy.swift
//  MapsIndoorsMapbox
//
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

/// Decides whether Mapbox Standard's 3D landmark models are drawn (SPEX-3206).
///
/// Landmarks are the textured towers Standard draws in large cities. `colorBuildings` does not fade them, the
/// venue clip layer removes them only inside a venue's outline, and a model cannot be faded, only shown or
/// hidden. A policy maps the building fade `MapboxWorldTransitionHandler` applies for the current world state
/// to that one decision, so the rule is chosen by configuration (`MPSettings3D.hideLandmarks`) without the
/// handler knowing which. The handler still never shows landmarks the style itself has switched off.
protocol MBLandmarkVisibilityPolicy: Sendable {
    /// - Parameters:
    ///   - buildingOpacity: The base-map building opacity for the current world state, from 0 to 1.
    ///   - nativeBuildingsEnabled: `false` when the host hides the base map's 3D content
    ///     (`MPFeatureType.extrudedBuildings`).
    /// - Returns: `true` when the landmarks are drawn.
    func showsLandmarks(buildingOpacity: Double, nativeBuildingsEnabled: Bool) -> Bool
}

/// The default. Landmarks are drawn only where the buildings are drawn at full opacity, so they leave with the
/// fade on the way into the MapsIndoors world instead of standing over the floor plan (JPMC 712 Main).
struct MBHideLandmarksWhileFadedPolicy: MBLandmarkVisibilityPolicy {
    func showsLandmarks(buildingOpacity: Double, nativeBuildingsEnabled: Bool) -> Bool {
        nativeBuildingsEnabled && buildingOpacity >= 1
    }
}

/// For solutions that want the landmarks at every zoom level. Only hiding the base map's 3D content as a whole
/// hides them.
struct MBKeepLandmarksPolicy: MBLandmarkVisibilityPolicy {
    func showsLandmarks(buildingOpacity _: Double, nativeBuildingsEnabled: Bool) -> Bool {
        nativeBuildingsEnabled
    }
}

enum MBLandmarkVisibility {
    /// The policy for the solution's `MPSettings3D.hideLandmarks`.
    static func policy(hidingLandmarks: Bool) -> any MBLandmarkVisibilityPolicy {
        hidingLandmarks ? MBHideLandmarksWhileFadedPolicy() : MBKeepLandmarksPolicy()
    }
}
