import Foundation
@preconcurrency import MapboxMaps
@_spi(Private) import MapsIndoorsCore

/// Owns the blue-dot layers on a Mapbox map. Main-actor isolated, because every call is a style write; the
/// `MPPositionPresenter` requirements are non-isolated and hop to the main actor with a `Task`, where the main-queue
/// async used to be.
@MainActor
final class MBPositionPresenter: MPPositionPresenter {
    private weak var map: MapboxMap?

    required init(map: MapboxMap?) {
        self.map = map
    }

    private let srcBlueDotCircle = "SOURCE_MP_BLUEDOT_CIRCLE"
    private let srcBlueDotMarker = "SOURCE_MP_BLUEDOT_MARKER"
    private let layerBlueDotCircle = "LAYER_MP_BLUEDOT_CIRCLE"
    private let layerBlueDotMarker = "LAYER_MP_BLUEDOT_MARKER"

    // Circle layers can't be lifted, so the accuracy circle of a raised position is a polygon instead.
    private let srcBlueDotAccuracy = "SOURCE_MP_BLUEDOT_ACCURACY"
    private let layerBlueDotAccuracyFill = "LAYER_MP_BLUEDOT_ACCURACY_FILL"
    private let layerBlueDotAccuracyLine = "LAYER_MP_BLUEDOT_ACCURACY_LINE"

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

    nonisolated func apply(
        position: CLLocationCoordinate2D,
        markerIcon: UIImage,
        markerBearing: Double,
        markerOpacity: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        apply(
            position: position, elevation: 0, markerIcon: markerIcon, markerBearing: markerBearing, markerOpacity: markerOpacity,
            circleRadiusMeters: circleRadiusMeters, circleFillColor: circleFillColor, circleStrokeColor: circleStrokeColor,
            circleStrokeWidth: circleStrokeWidth)
    }

    nonisolated func apply(
        position: CLLocationCoordinate2D,
        elevation: Double,
        markerIcon: UIImage,
        markerBearing: Double,
        markerOpacity: Double,
        circleRadiusMeters: Double,
        circleFillColor: UIColor,
        circleStrokeColor: UIColor,
        circleStrokeWidth: Double
    ) {
        // `map` is re-fetched after the hop: it is a weak var, and binding it here would let the dispatched
        // closure outlive the map.
        Task { @MainActor [weak self] in
            guard let self, let map = self.map, map.isStyleLoaded else { return }
            applyBlueDotUpdate(
                map: map,
                position: position,
                elevation: max(elevation, 0),
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
        elevation: Double,
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
        let elevated = elevation > 0
        do {
            try map.updateLayer(withId: layerBlueDotCircle, type: CircleLayer.self) { circleLayer in
                circleLayer.visibility = .constant(elevated ? .none : .visible)
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
        // Imperative, as the z-offset is experimental API and its default (0, grounding the dot) must land too.
        try? map.setLayerProperty(for: layerBlueDotMarker, property: "symbol-z-offset", value: elevation)

        applyAccuracyPolygon(
            map: map, position: position, elevation: elevated ? elevation : nil, radiusMeters: circleRadiusMeters,
            fillColor: circleFillColor, strokeColor: circleStrokeColor, strokeWidth: circleStrokeWidth)

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

    /// Draws the accuracy circle `elevation` meters up as a polygon and outline, or hides them for nil.
    private func applyAccuracyPolygon(
        map: MapboxMap, position: CLLocationCoordinate2D, elevation: Double?, radiusMeters: Double,
        fillColor: UIColor, strokeColor: UIColor, strokeWidth: Double
    ) {
        guard let elevation else {
            try? map.setLayerProperty(for: layerBlueDotAccuracyFill, property: "visibility", value: "none")
            try? map.setLayerProperty(for: layerBlueDotAccuracyLine, property: "visibility", value: "none")
            return
        }
        let ring = MBPositionPresenter.circleRing(center: position, radiusMeters: radiusMeters)
        map.updateGeoJSONSource(withId: srcBlueDotAccuracy, geoJSON: .feature(Feature(geometry: .polygon(Polygon([ring])))))

        // Opacities mirror the circle layer's.
        let fill: [String: Any] = [
            "fill-color": MBPositionPresenter.rgbaString(fillColor),
            "fill-opacity": 1 - fillColor.cgColor.alpha,
            "fill-emissive-strength": 1.0,
            "fill-z-offset": elevation,
            "visibility": "visible",
        ]
        let line: [String: Any] = [
            "line-color": MBPositionPresenter.rgbaString(strokeColor),
            "line-opacity": 1 - strokeColor.cgColor.alpha,
            "line-width": strokeWidth,
            "line-emissive-strength": 1.0,
            "line-elevation-reference": "ground",
            "line-z-offset": elevation,
            "visibility": "visible",
        ]
        for (layer, properties) in [(layerBlueDotAccuracyFill, fill), (layerBlueDotAccuracyLine, line)] {
            for (property, value) in properties {
                do {
                    try map.setLayerProperty(for: layer, property: property, value: value)
                } catch {
                    MPLog.mapbox.error("Blue dot \(property) rejected: \(error)")
                }
            }
        }
    }

    /// A closed ring approximating a circle on the ground.
    nonisolated static func circleRing(center: CLLocationCoordinate2D, radiusMeters: Double, segments: Int = 48) -> [CLLocationCoordinate2D] {
        let metersPerDegreeLat = 6_378_137.0 * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(center.latitude * .pi / 180)
        var ring = (0..<segments).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(segments)
            return CLLocationCoordinate2D(
                latitude: center.latitude + radiusMeters * cos(angle) / metersPerDegreeLat,
                longitude: center.longitude + radiusMeters * sin(angle) / metersPerDegreeLon)
        }
        ring.append(ring[0])
        return ring
    }

    /// `rgba(...)` string, the alpha kept as `StyleColor` keeps it for the circle layer.
    private nonisolated static func rgbaString(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), let converted = color.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) {
            UIColor(cgColor: converted).getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        return "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())), \(a))"
    }

    nonisolated func clear() {
        // See `apply` for why `map` is re-fetched inside the dispatched closure.
        Task { @MainActor [weak self] in
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

                for layer in [layerBlueDotAccuracyFill, layerBlueDotAccuracyLine] where map.layerExists(withId: layer) {
                    try map.setLayerProperty(for: layer, property: "visibility", value: "none")
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

            if map.sourceExists(withId: srcBlueDotAccuracy) == false {
                var source = GeoJSONSource(id: srcBlueDotAccuracy)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }

            // Between the circle and the marker, so a raised dot keeps the same stacking.
            if map.layerExists(withId: layerBlueDotAccuracyFill) == false {
                var fillLayer = FillLayer(id: layerBlueDotAccuracyFill, source: srcBlueDotAccuracy)
                fillLayer.slot = Self.blueDotSlot
                fillLayer.visibility = .constant(.none)
                try map.addLayer(fillLayer, layerPosition: .above(layerBlueDotCircle))
            }

            if map.layerExists(withId: layerBlueDotAccuracyLine) == false {
                var lineLayer = LineLayer(id: layerBlueDotAccuracyLine, source: srcBlueDotAccuracy)
                lineLayer.slot = Self.blueDotSlot
                lineLayer.visibility = .constant(.none)
                try map.addLayer(lineLayer, layerPosition: .above(layerBlueDotAccuracyFill))
            }

            if map.sourceExists(withId: srcBlueDotMarker) == false {
                var source = GeoJSONSource(id: srcBlueDotMarker)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }

            if map.layerExists(withId: layerBlueDotMarker) == false {
                var markerLayer = SymbolLayer(id: layerBlueDotMarker, source: srcBlueDotMarker)
                markerLayer.slot = Self.blueDotSlot
                try map.addLayer(markerLayer, layerPosition: .above(layerBlueDotAccuracyLine))
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
