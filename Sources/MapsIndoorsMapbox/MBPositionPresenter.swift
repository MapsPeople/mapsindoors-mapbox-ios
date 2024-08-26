import Foundation
import MapsIndoorsCore
import MapboxMaps

class MBPositionPresenter: MPPositionPresenter {
    
    private weak var map: MapboxMap?
    
    required init(map: MapboxMap?) {
        self.map = map
    }
    
    private let SRC_BLUEDOT_CIRCLE = "SOURCE_MP_BLUEDOT_CIRCLE"
    private let SRC_BLUEDOT_MARKER = "SOURCE_MP_BLUEDOT_MARKER"
    private let LAYER_BLUEDOT_CIRCLE = "LAYER_MP_BLUEDOT_CIRCLE"
    private let LAYER_BLUEDOT_MARKER = "LAYER_MP_BLUEDOT_MARKER"
    
    private let BLUEDOT_ICON_ID = "MP_BLUEDOT_ICON"
    private let BLUEDOT_CIRCLE_SIZE_ID = "MP_BLUEDOT_CIRLCE_SIZE"
 
    func apply(position: CLLocationCoordinate2D,
               markerIcon: UIImage,
               markerBearing: Double,
               markerOpacity: Double,
               circleRadiusMeters: Double,
               circleFillColor: UIColor,
               circleStrokeColor: UIColor,
               circleStrokeWidth: Double) {
        guard let map else { return }
        
        DispatchQueue.main.async { [self] in
            addSourcesAndLayersIfNotPresent()
            do {
                try map.moveLayer(withId: LAYER_BLUEDOT_CIRCLE, to: .above(Constants.LayerIDs.tileLayer))
                try map.moveLayer(withId: LAYER_BLUEDOT_MARKER, to: .above(LAYER_BLUEDOT_CIRCLE))
                
                try map.updateLayer(withId: LAYER_BLUEDOT_CIRCLE, type: CircleLayer.self) { circleLayer in
                    circleLayer.visibility = .constant(.visible)
                    circleLayer.circleColor = .constant(StyleColor(circleFillColor))
                    circleLayer.circleOpacity = .constant(1-circleFillColor.cgColor.alpha)
                    circleLayer.circleStrokeColor = .constant(StyleColor(circleStrokeColor))
                    circleLayer.circleStrokeOpacity = .constant(1-circleStrokeColor.cgColor.alpha)
                    circleLayer.circleStrokeWidth = .constant(circleStrokeWidth)
                    circleLayer.slot = "top"
                    circleLayer.circleEmissiveStrength = .constant(1.0)
                }
                
                try map.updateLayer(withId: LAYER_BLUEDOT_MARKER, type: SymbolLayer.self) { markerLayer in
                    markerLayer.visibility = .constant(.visible)
                    markerLayer.iconOpacity = .constant(markerOpacity)
                    markerLayer.iconRotate = .constant(markerBearing)
                    markerLayer.iconImage = .expression(Exp(.image) { Exp(.literal) { BLUEDOT_ICON_ID } })
                    markerLayer.iconRotationAlignment = .constant(.map)
                    markerLayer.iconPitchAlignment = .constant(.map)
                    markerLayer.iconAllowOverlap = .constant(true)
                    markerLayer.textAllowOverlap = .constant(true)
                    markerLayer.slot = "top"
                }
                
                let circleSize = circleRadiusMeters / (cos(position.latitude * (.pi / 180)) * 0.019)
                var bluedotFeature = Feature.init(geometry: .point(Point(position)))
                bluedotFeature.properties = [BLUEDOT_CIRCLE_SIZE_ID: .number(circleSize)]

                map.updateGeoJSONSource(withId: SRC_BLUEDOT_MARKER, geoJSON: GeoJSONObject.feature(bluedotFeature))
                map.updateGeoJSONSource(withId: SRC_BLUEDOT_CIRCLE, geoJSON: GeoJSONObject.feature(bluedotFeature))

                try map.addImage(markerIcon, id: BLUEDOT_ICON_ID, sdf: false)
                
            } catch {
                MPLog.mapbox.error("Error attempting to update blue dot layers: " + error.localizedDescription)
            }
        }
        
    }
    
    func clear() {
        guard let map else { return }
        
        DispatchQueue.main.async { [self] in
            do {
                var circleLayer = try map.layer(withId: LAYER_BLUEDOT_CIRCLE) as? CircleLayer
                circleLayer?.visibility = .constant(.none)
                
                var markerLayer = try map.layer(withId: LAYER_BLUEDOT_MARKER) as? SymbolLayer
                markerLayer?.visibility = .constant(.none)
            } catch { }
        }
    }
    
    private func addSourcesAndLayersIfNotPresent() {
        guard let map else { return }

        do {
            if map.sourceExists(withId: SRC_BLUEDOT_CIRCLE) == false {
                var source = GeoJSONSource(id: SRC_BLUEDOT_CIRCLE)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }
            
            if map.layerExists(withId: LAYER_BLUEDOT_CIRCLE) == false {
                var circleLayer = CircleLayer(id: LAYER_BLUEDOT_CIRCLE, source: SRC_BLUEDOT_CIRCLE)
                circleLayer.circlePitchAlignment = .constant(.map)
                circleLayer.circlePitchScale = .constant(.map)

                let stops: [Double: Exp] = [
                    1: Exp(.product) {
                        MBRenderer.zoom22Scale
                        Exp(.get) { Exp(.literal) { BLUEDOT_CIRCLE_SIZE_ID } }
                    }
                    ,
                    22: Exp(.get) { Exp(.literal) { BLUEDOT_CIRCLE_SIZE_ID } }
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
            
            if map.sourceExists(withId: SRC_BLUEDOT_MARKER) == false {
                var source = GeoJSONSource(id: SRC_BLUEDOT_MARKER)
                source.data = .featureCollection(FeatureCollection(features: []))
                try map.addSource(source)
            }
            
            if map.layerExists(withId: LAYER_BLUEDOT_MARKER) == false {
                var markerLayer = SymbolLayer(id: LAYER_BLUEDOT_MARKER, source: SRC_BLUEDOT_MARKER)
                try map.addLayer(markerLayer, layerPosition: .above(LAYER_BLUEDOT_CIRCLE))
            }
            
        } catch {
            MPLog.mapbox.error("Error attempting to create blue dot sources and layers: " + error.localizedDescription)
        }
        
    }

}
