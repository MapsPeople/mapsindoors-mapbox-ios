import Foundation
import MapboxMaps
import MapsIndoorsCore

class MBPositionPresenter: MPPositionPresenter {
    private weak var map: MapboxMap?

    required init(map: MapboxMap?) {
        self.map = map
    }

    private let srcBlueDotCircle = "SOURCE_MP_BLUEDOT_CIRCLE"
    private let srcBlueDotMarker = "SOURCE_MP_BLUEDOT_MARKER"
    private let layerBlueDotCircle = "LAYER_MP_BLUEDOT_CIRCLE"
    private let layerBlueDotMarker = "LAYER_MP_BLUEDOT_MARKER"

    private let blueDotIconId = "MP_BLUEDOT_ICON"
    private let blueDotCircleSizeId = "MP_BLUEDOT_CIRLCE_SIZE"

    /// The slot the blue dot layers live in — above "middle", where all other
    /// MapsIndoors content (including the route) is placed. These layers are created
    /// here rather than in `addMapsIndoorsLayers()`, so they are deliberately outside
    /// `Constants.slotForLayerId` (see its doc comment).
    ///
    /// `internal` rather than `private` so the slot-contract test can assert it is a
    /// valid slot — `Slot`'s string-literal init does not validate, so a typo compiles.
    static let blueDotSlot: Slot = "top"

    func apply(
        position: CLLocationCoordinate2D,
        markerIcon: UIImage,
        markerBearing: Double,
        markerOpacity: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        // Fast-path early-out only. Do not bind `map` here: it's a weak var,
        // and binding strongly would let the dispatched closure outlive the
        // map, defeating the inner re-fetch from `self.map` after the hop.
        guard map != nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let map = self.map, map.isStyleLoaded else { return }
            applyBlueDotUpdate(
                map: map,
                position: position,
                markerIcon: markerIcon,
                markerOpacity: markerOpacity,
                markerBearing: markerBearing,
                circleRadiusMeters: circleRadiusMeters,
                circleFillColor: circleFillColor,
                circleStrokeColor: circleStrokeColor,
                circleStrokeWidth: circleStrokeWidth)
        }
    }

    private func applyBlueDotUpdate(
        map: MapboxMap,
        position: CLLocationCoordinate2D,
        markerIcon: UIImage,
        markerOpacity: Double,
        markerBearing: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        addSourcesAndLayersIfNotPresent()

        // No moveLayer here: the layers' "top" slot decides render order, so a
        // positional move is redundant. Each step is also caught independently: a
        // throw in one (e.g. an updateLayer on a layer that failed to create) must
        // not skip the source and icon updates that actually place and draw the dot.
        do {
            try map.updateLayer(withId: layerBlueDotCircle, type: CircleLayer.self) { circleLayer in
                circleLayer.visibility = .constant(.visible)
                circleLayer.circleColor = .constant(StyleColor(circleFillColor))
                circleLayer.circleOpacity = .constant(1 - circleFillColor.cgColor.alpha)
                circleLayer.circleStrokeColor = .constant(StyleColor(circleStrokeColor))
                circleLayer.circleStrokeOpacity = .constant(1 - circleStrokeColor.cgColor.alpha)
                circleLayer.circleStrokeWidth = .constant(circleStrokeWidth)
                circleLayer.slot = Self.blueDotSlot
                circleLayer.circleEmissiveStrength = .constant(1.0)
            }
        } catch {
            MPLog.mapbox.error("Error updating blue dot circle layer: " + error.localizedDescription)
        }

        do {
            try map.updateLayer(withId: layerBlueDotMarker, type: SymbolLayer.self) { markerLayer in
                markerLayer.visibility = .constant(.visible)
                markerLayer.iconOpacity = .constant(markerOpacity)
                markerLayer.iconRotate = .constant(markerBearing)
                markerLayer.iconImage = .expression(Exp(.image) { Exp(.literal) { blueDotIconId } })
                markerLayer.iconRotationAlignment = .constant(.map)
                markerLayer.iconPitchAlignment = .constant(.map)
                markerLayer.iconAllowOverlap = .constant(true)
                markerLayer.textAllowOverlap = .constant(true)
                markerLayer.slot = Self.blueDotSlot
            }
        } catch {
            MPLog.mapbox.error("Error updating blue dot marker layer: " + error.localizedDescription)
        }

        let circleSize = circleRadiusMeters / (cos(position.latitude * (.pi / 180)) * 0.019)
        var bluedotFeature = Feature(geometry: .point(Point(position)))
        bluedotFeature.properties = [blueDotCircleSizeId: .number(circleSize)]

        map.updateGeoJSONSource(withId: srcBlueDotMarker, geoJSON: GeoJSONObject.feature(bluedotFeature))
        map.updateGeoJSONSource(withId: srcBlueDotCircle, geoJSON: GeoJSONObject.feature(bluedotFeature))

        do {
            try map.addImage(markerIcon, id: blueDotIconId, sdf: false)
        } catch {
            MPLog.mapbox.error("Error adding blue dot marker image: " + error.localizedDescription)
        }
    }

    func clear() {
        // See `apply` for why we don't bind `map` here: weak var, re-fetched
        // inside the dispatched closure to observe deallocation after hop.
        guard map != nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let map = self.map, map.isStyleLoaded else { return }
            do {
                if map.layerExists(withId: layerBlueDotCircle) {
                    try map.updateLayer(withId: layerBlueDotCircle, type: CircleLayer.self) { circleLayer in
                        circleLayer.visibility = .constant(.none)
                    }
                }

                if map.layerExists(withId: layerBlueDotMarker) {
                    try map.updateLayer(withId: layerBlueDotMarker, type: SymbolLayer.self) { markerLayer in
                        markerLayer.visibility = .constant(.none)
                    }
                }
            } catch {}
        }
    }

    private func addSourcesAndLayersIfNotPresent() {
        guard let map else { return }

        do {
            if map.sourceExists(withId: srcBlueDotCircle) == false {
                var source = GeoJSONSource(id: srcBlueDotCircle)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }

            if map.layerExists(withId: layerBlueDotCircle) == false {
                var circleLayer = CircleLayer(id: layerBlueDotCircle, source: srcBlueDotCircle)
                circleLayer.circlePitchAlignment = .constant(.map)
                circleLayer.circlePitchScale = .constant(.map)

                let stops: [Double: Exp] = [
                    1: Exp(.product) {
                        MBRenderer.zoom22Scale
                        Exp(.get) { Exp(.literal) { blueDotCircleSizeId } }
                    },

                    22: Exp(.get) { Exp(.literal) { blueDotCircleSizeId } },
                ]

                circleLayer.circleRadius = .expression(
                    Exp(.interpolate) {
                        Exp(.exponential) { 2 }
                        Exp(.zoom)
                        stops
                    }
                )

                circleLayer.slot = Self.blueDotSlot
                // Anchor above the top-most existing MapsIndoors layer, not TILE_LAYER
                // (the bottom-most). On a slot-aware style the "top" slot already orders
                // the dot above "middle"; but on a style with no slots — reachable via
                // useMapsIndoorsStyle(false) or offline — insertion order is all there is,
                // and .above(TILE_LAYER) would leave the route drawing over the dot
                // (SPEX-2354/SPEX-2355). If no MapsIndoors layer exists yet, add unpositioned.
                if let anchor = topMostMapsIndoorsLayerId(in: map) {
                    try map.addLayer(circleLayer, layerPosition: .above(anchor))
                } else {
                    try map.addLayer(circleLayer)
                }
            }

            if map.sourceExists(withId: srcBlueDotMarker) == false {
                var source = GeoJSONSource(id: srcBlueDotMarker)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }

            if map.layerExists(withId: layerBlueDotMarker) == false {
                var markerLayer = SymbolLayer(id: layerBlueDotMarker, source: srcBlueDotMarker)
                markerLayer.slot = Self.blueDotSlot
                try map.addLayer(markerLayer, layerPosition: .above(layerBlueDotCircle))
            }
        } catch {
            MPLog.mapbox.error("Error attempting to create blue dot sources and layers: " + error.localizedDescription)
        }
    }

    /// The top-most MapsIndoors layer currently in the style, in render/insertion order,
    /// or nil if none exist yet. `allLayerIdentifiers` is bottom-to-top, so the last match
    /// is the highest. Membership is decided by the slot registry — the authoritative set
    /// of MapsIndoors layer ids — so basemap layers are never picked as the anchor.
    private func topMostMapsIndoorsLayerId(in map: MapboxMap) -> String? {
        map.allLayerIdentifiers.last { Constants.slotForLayerId.keys.contains($0.id) }?.id
    }
}
