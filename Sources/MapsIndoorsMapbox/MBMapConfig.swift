import Foundation
import MapboxMaps
import MapsIndoors

/// Extending MPMapConfig with an initializer for Mapbox
@objc extension MPMapConfig {
    public convenience init(mapBoxView: MapView, accessToken: String) {
        self.init()
        let mapboxProvider = MapBoxProvider(mapView: mapBoxView, accessToken: accessToken)
        mapProvider = mapboxProvider
    }

    /// Set the zoom level, where the map will transition from Mapbox-centric to MapsIndoors-centric, in terms of showing world and indoor features.
    public func setMapsIndoorsTransitionLevel(zoom: Int) {
        (mapProvider as? MapBoxProvider)?.transitionLevel = zoom
    }

    /// Set whether to allow showing the map engine's POIs.
    public func setShowMapMarkers(show: Bool) {
        (mapProvider as? MapBoxProvider)?.showMapboxMapMarkers = show
    }

    /// Set whether to allow showing the map engine's road labels.
    public func setShowRoadLabels(show: Bool) {
        (mapProvider as? MapBoxProvider)?.showMapboxRoadLabels = show
    }

    /// Set whether to use the MapsIndoors Mapbox map style. If set to `false`, the MapsIndoors SDK will not attempt to apply any Mapbox map style, only layers/sources to render MapsIndoors content. Default is `true`.
    public func useMapsIndoorsStyle(value: Bool) {
        (mapProvider as? MapBoxProvider)?.useMapsIndoorsStyle = value
    }

    /// Set whether to hide the Mapbox logo. Default is `false` (the Mapbox logo is shown),
    /// matching the Android SDK's `hideMapboxLogo` option. When set to `true`, the Mapbox
    /// logo is suppressed and the MapsPeople branding logo occupies the bottom-left
    /// watermark slot. The map provider attribution remains visible in either case.
    public func setHideMapboxLogo(hide: Bool) {
        (mapProvider as? MapBoxProvider)?.hideMapboxLogo = hide
    }
}
