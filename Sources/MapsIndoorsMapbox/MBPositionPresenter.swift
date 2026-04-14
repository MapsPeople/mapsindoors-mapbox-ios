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
        guard let map else { return }

        DispatchQueue.main.async { [self] in
            addSourcesAndLayersIfNotPresent()
            do {
                try map.moveLayer(withId: layerBlueDotCircle, to: .above(Constants.LayerIDs.tileLayer))
                try map.moveLayer(withId: layerBlueDotMarker, to: .above(layerBlueDotCircle))

                try map.updateLayer(withId: layerBlueDotCircle, type: CircleLayer.self) { circleLayer in
                    circleLayer.visibility = .constant(.visible)
                    circleLayer.circleColor = .constant(StyleColor(circleFillColor))
                    circleLayer.circleOpacity = .constant(1 - circleFillColor.cgColor.alpha)
                    circleLayer.circleStrokeColor = .constant(StyleColor(circleStrokeColor))
                    circleLayer.circleStrokeOpacity = .constant(1 - circleStrokeColor.cgColor.alpha)
                    circleLayer.circleStrokeWidth = .constant(circleStrokeWidth)
                    circleLayer.slot = "top"
                    circleLayer.circleEmissiveStrength = .constant(1.0)
                }

                try map.updateLayer(withId: layerBlueDotMarker, type: SymbolLayer.self) { markerLayer in
                    markerLayer.visibility = .constant(.visible)
                    markerLayer.iconOpacity = .constant(markerOpacity)
                    markerLayer.iconRotate = .constant(markerBearing)
                    markerLayer.iconImage = .expression(Exp(.image) { Exp(.literal) { blueDotIconId } })
                    markerLayer.iconRotationAlignment = .constant(.map)
                    markerLayer.iconPitchAlignment = .constant(.map)
                    markerLayer.iconAllowOverlap = .constant(true)
                    markerLayer.textAllowOverlap = .constant(true)
                    markerLayer.slot = "top"
                }

                let circleSize = circleRadiusMeters / (cos(position.latitude * (.pi / 180)) * 0.019)
                var bluedotFeature = Feature(geometry: .point(Point(position)))
                bluedotFeature.properties = [blueDotCircleSizeId: .number(circleSize)]

                map.updateGeoJSONSource(withId: srcBlueDotMarker, geoJSON: GeoJSONObject.feature(bluedotFeature))
                map.updateGeoJSONSource(withId: srcBlueDotCircle, geoJSON: GeoJSONObject.feature(bluedotFeature))

                try map.addImage(markerIcon, id: blueDotIconId, sdf: false)
            } catch {
                MPLog.mapbox.error("Error attempting to update blue dot layers: " + error.localizedDescription)
            }
        }
    }

    func clear() {
        guard let map else { return }

        DispatchQueue.main.async { [self] in
            do {
                try map.updateLayer(withId: layerBlueDotCircle, type: CircleLayer.self) { circleLayer in
                    circleLayer.visibility = .constant(.none)
                }

                try map.updateLayer(withId: layerBlueDotMarker, type: SymbolLayer.self) { markerLayer in
                    markerLayer.visibility = .constant(.none)
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

                try map.addLayer(circleLayer, layerPosition: .above(Constants.LayerIDs.tileLayer))
            }

            if map.sourceExists(withId: srcBlueDotMarker) == false {
                var source = GeoJSONSource(id: srcBlueDotMarker)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }

            if map.layerExists(withId: layerBlueDotMarker) == false {
                let markerLayer = SymbolLayer(id: layerBlueDotMarker, source: srcBlueDotMarker)
                try map.addLayer(markerLayer, layerPosition: .above(layerBlueDotCircle))
            }
        } catch {
            MPLog.mapbox.error("Error attempting to create blue dot sources and layers: " + error.localizedDescription)
        }
    }
}
