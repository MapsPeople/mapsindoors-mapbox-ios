import Foundation
import MapboxMaps
import MapsIndoors

/// Extending MPMapConfig with an initializer for Mapbox
@objc public extension MPMapConfig {
    convenience init(mapBoxView: MapView, accessToken: String) {
        self.init()
        let mapboxProvider = MapBoxProvider(mapView: mapBoxView, accessToken: accessToken)
        mapProvider = mapboxProvider
    }

    /// Set the zoom level, where the map will transition from Mapbox-centric to MapsIndoors-centric, in terms of showing world and indoor features.
    func setMapsIndoorsTransitionLevel(zoom: Int) {
        (mapProvider as? MapBoxProvider)?.transitionLevel = zoom
    }

    /// Set whether to allow showing the map engine's POIs.
    func setShowMapMarkers(show: Bool) {
        (mapProvider as? MapBoxProvider)?.showMapboxMapMarkers = show
    }

    /// Set whether to allow showing the map engine's road labels.
    func setShowRoadLabels(show: Bool) {
        (mapProvider as? MapBoxProvider)?.showMapboxRoadLabels = show
    }
    
    /// Set whether to use the MapsIndoors Mapbox map style. If set to `false`, the MapsIndoors SDK will not attempt to apply any Mapbox map style, only layers/sources to render MapsIndoors content. Default is `true`.
    func useMapsIndoorsStyle(value: Bool) {
        (mapProvider as? MapBoxProvider)?.useMapsIndoorsStyle = value
    }
    
}
