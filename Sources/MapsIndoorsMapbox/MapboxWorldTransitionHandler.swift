import Foundation
import MapboxMaps
import MapsIndoorsCore

class MapboxWorldTransitionHandler {
    
    private let baseMap = "basemap"
    private let placeLabels = "showPlaceLabels"
    private let roadLabels = "showRoadLabels"
    private let poiLabels = "showPointOfInterestLabels"
    private let buildingOpacity = "buildingsOpacity"
    
    weak var map: MapBoxProvider?
    var enableMapboxBuildings = true {
        didSet {
            Task {
                await self.configureMapsIndoorsVsMapboxVisiblity()
            }
        }
    }
    
    required init(mapProvider: MapBoxProvider) {
        map = mapProvider
    }
    
    @MainActor
    func configureMapsIndoorsVsMapboxVisiblity() async {
        guard let map, let mapboxMap = map.mapView?.mapboxMap else { return }
        
        do {
            if let showPlacesAndPois = map.showMapboxMapMarkers {
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: showPlacesAndPois)
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: showPlacesAndPois)
            } else {
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
            }
            if let showRoads = map.showMapboxRoadLabels {
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: showRoads)
            } else {
                try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
            }

            let currentZoom = Double(map.cameraOperator.position.zoom - 1)
            let transition = Double(map.transitionLevel)
            
            if currentZoom > transition + 1 {
                try applyShowMapsIndoorsWorld()
            } else if currentZoom < transition {
                try applyShowMapboxWorld()
            } else {
                try applyShowIntermediaryWorld()
            }
            
            if self.enableMapboxBuildings == false {
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
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
        
        if let show = map.showMapboxMapMarkers, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
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
        
        try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: self.enableMapboxBuildings ? 1.0 : 0.0)
        if let show = map.showMapboxMapMarkers, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
        }
        if let show = map.showMapboxRoadLabels, show == true {
            try mapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        }
    }
    
}
