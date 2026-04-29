import Foundation
import MapboxMaps
import MapsIndoorsCore

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
                await self?.configureMapsIndoorsVsMapboxVisiblity()
            }
        }
    }

    required init(mapProvider: MapBoxProvider) {
        map = mapProvider
    }

    /// Tracks the last applied world state to avoid redundant style config calls
    private enum WorldState: Equatable { case mapsindoors, mapbox, intermediary }
    private var lastAppliedWorldState: WorldState?
    /// Tracks the last applied marker/road label config to avoid redundant calls
    private var lastAppliedMarkerConfig: (showMarkers: Bool?, showRoads: Bool?)?

    @MainActor
    func configureMapsIndoorsVsMapboxVisiblity() async {
        guard let map, let mapboxMap = map.mapView?.mapboxMap else { return }

        do {
            // Only apply marker/label config when it actually changes
            let currentMarkerConfig = (showMarkers: map.showMapboxMapMarkers, showRoads: map.showMapboxRoadLabels)
            let markerConfigChanged = lastAppliedMarkerConfig == nil
                || lastAppliedMarkerConfig?.showMarkers != currentMarkerConfig.showMarkers
                || lastAppliedMarkerConfig?.showRoads != currentMarkerConfig.showRoads

            if markerConfigChanged {
                if let showPlacesAndPois = map.showMapboxMapMarkers {
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: showPlacesAndPois)
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: showPlacesAndPois)
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: showPlacesAndPois)
                } else {
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
                }
                if let showRoads = map.showMapboxRoadLabels {
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: showRoads)
                } else {
                    try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
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
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.0)
            }
        } catch {
            MPLog.mapbox.info("Failed to configure style config properties.")
        }
    }

    /// Hide all Mapbox content which interfering with MapsIndoors content
    private func applyShowMapsIndoorsWorld() throws {
        guard let map, let mapboxMap = map.mapView?.mapboxMap else { return }

        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.0)
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)

        if let show = map.showMapboxMapMarkers, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
        }
        if let show = map.showMapboxRoadLabels, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        }
    }

    private func applyShowIntermediaryWorld() throws {
        guard let map, let mapboxMap = map.mapView?.mapboxMap else { return }
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 0.5)
    }

    /// Show all Mapbox content, if enabled
    private func applyShowMapboxWorld() throws {
        guard let map, let mapboxMap = map.mapView?.mapboxMap else { return }

        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: enableMapboxBuildings ? 1.0 : 0.0)
        if let show = map.showMapboxMapMarkers, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
        }
        if let show = map.showMapboxRoadLabels, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        }
    }
}
