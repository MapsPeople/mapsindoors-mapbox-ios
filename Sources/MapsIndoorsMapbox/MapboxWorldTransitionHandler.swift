import Foundation
import MapboxMaps
import MapsIndoorsCore

/// Test seam over the subset of `MapboxMap` this handler actually exercises.
/// Tests inject a recording fake to assert per-flag writes without standing up
/// a real Mapbox style.
protocol MBStyleImportConfigSetting: AnyObject {
    func setStyleImportConfigProperty(for importId: String, config: String, value: Any) throws
}

extension MapboxMap: MBStyleImportConfigSetting {}

@MainActor
class MapboxWorldTransitionHandler {
    private let baseMap = "basemap"
    private let placeLabels = "showPlaceLabels"
    private let transitLabels = "showTransitLabels"
    private let roadLabels = "showRoadLabels"
    private let poiLabels = "showPointOfInterestLabels"
    private let buildingOpacity = "buildingsOpacity"

    weak var map: MapBoxProvider?
    var enableMapboxBuildings = true {
        didSet {
            // Reset cached state so the next call applies the change
            lastAppliedWorldState = nil
            lastAppliedMarkerConfig = nil
            Task { [weak self] in
                await self?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
    }

    nonisolated required init(mapProvider: MapBoxProvider) {
        map = mapProvider
    }

    /// Tracks the last applied world state to avoid redundant style config calls
    private enum WorldState: Equatable { case mapsindoors, mapbox, intermediary }
    private var lastAppliedWorldState: WorldState?
    /// Tracks the last applied marker/road label config to avoid redundant calls
    private var lastAppliedMarkerConfig: (showMarkers: Bool?, showRoads: Bool?)?

    /// Test injection point — when non-nil, all style-import writes route here
    /// instead of the live `MapboxMap`. Internal so `@testable import` tests can
    /// assert the exact writes per flag combination.
    internal var mapboxMapOverride: MBStyleImportConfigSetting?

    private var activeMapboxMap: MBStyleImportConfigSetting? {
        mapboxMapOverride ?? map?.mapView?.mapboxMap
    }

    /// Overridable so tests can subclass via `@testable import` and count invocations
    /// scheduled by `MapBoxProvider` property didSet observers.
    func configureMapsIndoorsVsMapboxVisibility() async {
        guard let map, let activeMapboxMap else { return }

        do {
            // Only apply marker/label config when it actually changes
            let currentMarkerConfig = (showMarkers: map.showMapboxMapMarkers, showRoads: map.showMapboxRoadLabels)
            let markerConfigChanged =
                lastAppliedMarkerConfig == nil
                || lastAppliedMarkerConfig?.showMarkers != currentMarkerConfig.showMarkers
                || lastAppliedMarkerConfig?.showRoads != currentMarkerConfig.showRoads

            if markerConfigChanged {
                if map.showMapboxMapMarkers == true {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
                } else {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
                }
                if map.showMapboxRoadLabels == true {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
                } else {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
                }
                lastAppliedMarkerConfig = currentMarkerConfig
            }

            let currentZoom = Double(map.cameraOperator.position.zoom - 1)
            let transition = Double(map.transitionLevel)

            let newWorldState: WorldState
            if currentZoom > transition + 1 {
                newWorldState = .mapsindoors
            } else if currentZoom < transition {
                newWorldState = .mapbox
            } else {
                newWorldState = .intermediary
            }

            // Skip redundant style updates when world state hasn't changed
            if newWorldState != lastAppliedWorldState {
                lastAppliedWorldState = newWorldState
                switch newWorldState {
                case .mapsindoors:
                    try applyShowMapsIndoorsWorld()
                case .mapbox:
                    try applyShowMapboxWorld()
                case .intermediary:
                    try applyShowIntermediaryWorld()
                }
            }

            if enableMapboxBuildings == false {
                try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.0)
            }
        } catch {
            MPLog.mapbox.info("Failed to configure style config properties.")
        }
    }

    /// Hide all Mapbox content which interfering with MapsIndoors content
    private func applyShowMapsIndoorsWorld() throws {
        guard let map, let activeMapboxMap else { return }

        try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.0)

        if map.showMapboxMapMarkers == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
        }

        if map.showMapboxRoadLabels == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
        }
    }

    private func applyShowIntermediaryWorld() throws {
        guard let activeMapboxMap else { return }
        try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.5)
    }

    /// Show all Mapbox content, if enabled
    private func applyShowMapboxWorld() throws {
        guard let map, let activeMapboxMap else { return }

        try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: enableMapboxBuildings ? 1.0 : 0.0)

        if map.showMapboxMapMarkers == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
        }

        if map.showMapboxRoadLabels == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
        }
    }
}
