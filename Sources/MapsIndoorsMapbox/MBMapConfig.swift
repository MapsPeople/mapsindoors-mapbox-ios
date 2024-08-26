import Foundation
import MapboxMaps
import MapsIndoors

/// Extending MPMapConfig with an initializer for Mapbox
@objc public extension MPMapConfig {
    
    convenience init(mapBoxView: MapView, accessToken: String) {
        self.init()
        let mapboxProvider = MapBoxProvider(mapView: mapBoxView, accessToken: accessToken)
        self.mapProvider = mapboxProvider
    }
    
    /// Set the zoom level, where the map will transition from Mapbox-centric to MapsIndoors-centric, in terms of showing world and indoor features.
    func setMapsIndoorsTransitionLevel(zoom: Int) {
        (self.mapProvider as? MapBoxProvider)?.transitionLevel = zoom
    }
    
    /// Set whether to allow showing the map engine's POIs.
    func setShowMapMarkers(show: Bool) {
        (self.mapProvider as? MapBoxProvider)?.showMapboxMapMarkers = show
    }
    
    /// Set whether to allow showing the map engine's road labels.
    func setShowRoadLabels(show: Bool) {
        (self.mapProvider as? MapBoxProvider)?.showMapboxRoadLabels = show
    }
    
    var showMapMarkers: Bool {
        set {
            (self.mapProvider as? MapBoxProvider)?.showMapboxMapMarkers = newValue
        }
        get {
            (self.mapProvider as? MapBoxProvider)?.showMapboxMapMarkers ?? false
        }
    }
    
    var showRoadLabels: Bool {
        set {
            (self.mapProvider as? MapBoxProvider)?.showMapboxRoadLabels = newValue
        }
        get {
            (self.mapProvider as? MapBoxProvider)?.showMapboxRoadLabels ?? false
        }
    }
}
