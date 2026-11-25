//
//  MBBaseMapStyleContract.swift
//  MapsIndoorsMapbox
//
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation

/// One config option of the base-map style that the Mapbox provider depends on.
///
/// The name and the value type are Mapbox's, from the style's `schema`. The style can change them
/// with no change in this repo, which is why they are declared in one place and not as string
/// literals where they are used (SPEX-3247): a declared option can be compared with a style.
struct MBBaseMapStyleOption: Hashable, Sendable {
    /// The `type` of the option in the style's schema.
    enum ValueType: String, Sendable {
        case boolean
        case color
        /// No current option is a number. `buildingsOpacity` was, up to 4.23.0, and the contract of
        /// that release is written down in the tests.
        case number
    }

    /// What the provider does with the option's value.
    enum Access: Sendable {
        /// Written, never read back.
        case write
        /// Read to learn the style's or the host's own value, then written.
        case readWrite
    }

    /// What the provider uses the option for, which is also what drives its value.
    enum Purpose: Sendable {
        /// Base-map labels, from `showMapboxMapMarkers` and `showMapboxRoadLabels`.
        case labelVisibility
        /// The fade of the base map's buildings across the transition band, from the camera zoom
        /// against `transitionLevel` and from `enableMapboxBuildings`.
        case buildingFade
        /// The base map's landmark models, from the building fade and `MPSettings3D.hideLandmarks`.
        case landmarkVisibility
    }

    let name: String
    let valueType: ValueType
    let access: Access
    let purpose: Purpose

    /// Whether `value` is of the kind the style expects for this option.
    func accepts(_ value: Any) -> Bool {
        switch valueType {
        case .boolean: value is Bool
        case .color: value is String
        case .number: value is Double || value is Int
        }
    }
}

extension MBBaseMapStyleOption {
    static let showPlaceLabels = MBBaseMapStyleOption(
        name: "showPlaceLabels", valueType: .boolean, access: .write, purpose: .labelVisibility)
    static let showTransitLabels = MBBaseMapStyleOption(
        name: "showTransitLabels", valueType: .boolean, access: .write, purpose: .labelVisibility)
    static let showRoadLabels = MBBaseMapStyleOption(
        name: "showRoadLabels", valueType: .boolean, access: .write, purpose: .labelVisibility)
    static let showPointOfInterestLabels = MBBaseMapStyleOption(
        name: "showPointOfInterestLabels", valueType: .boolean, access: .write, purpose: .labelVisibility)

    /// Mapbox Standard's building colour config ("Set a custom color for 3D & 2D buildings"). The sole
    /// mechanism for fading base-map buildings across the transition band (SPEX-2517): Standard derives
    /// building opacity from its alpha, online and offline alike. It replaces `buildingsOpacity`, which
    /// existed only in an experimental basemap and had no effect offline, and the `show3dObjects`
    /// fallback, which also hid landmark models and trees.
    static let colorBuildings = MBBaseMapStyleOption(
        name: "colorBuildings", valueType: .color, access: .readWrite, purpose: .buildingFade)

    /// Standard's toggle for its 3D landmark models (the textured towers in large cities). They are
    /// not buildings to `colorBuildings`, so the fade leaves them solid, and the clip layer removes
    /// 3D content only inside the venue outlines. A landmark next to a venue then stands at full
    /// height in front of the floor plan under a pitched camera, covering the POIs that are drawn on
    /// it (JPMC 712 Main, SPEX-3206). Models cannot be faded, only shown or hidden.
    static let show3dLandmarks = MBBaseMapStyleOption(
        name: "show3dLandmarks", valueType: .boolean, access: .readWrite, purpose: .landmarkVisibility)
}

/// Everything the Mapbox provider reads from or writes to the base-map style's config: the import
/// it addresses and the options on it.
///
/// It is complete because only `MapboxWorldTransitionHandler` touches the config, through its
/// `MBStyleImportConfigSetting` seam. Rule M1 of `Scripts/architecture/catch_code_issues.sh` rejects
/// a config call anywhere else in the provider.
///
/// ``current`` is what this version of the SDK depends on. It is a value so that the contract of an
/// earlier release can be written down next to it and both can be checked against a style.
struct MBBaseMapStyleContract: Equatable, Sendable {
    /// The id of the style import that carries the options. Mapbox also answers to it when Standard
    /// is loaded as the style itself and not as an import.
    let importId: String
    let options: [MBBaseMapStyleOption]

    static let current = MBBaseMapStyleContract(
        importId: "basemap",
        options: [
            .showPlaceLabels,
            .showTransitLabels,
            .showRoadLabels,
            .showPointOfInterestLabels,
            .colorBuildings,
            .show3dLandmarks,
        ])

    /// The declared option with this name, or `nil` when the contract does not cover it.
    func option(named name: String) -> MBBaseMapStyleOption? {
        options.first { $0.name == name }
    }
}
