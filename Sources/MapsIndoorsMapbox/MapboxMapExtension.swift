import Foundation
import MapboxMaps
import MapsIndoorsCore

@objc public extension MapboxMap {
    
    /// Returns a `String` ID of a MapsIndoors Layer, internally used to render content on map engine `Mapbox`
    /// - Parameter mpLayer: `MPLayer` type as abstracted for Mapbox `Layer`used to render MapsIndoors content internally. Use the dot`.` notation
    /// - Returns: `String`. Id of layer
    func getMapsIndoorsMapboxLayerId(for mpLayer: MPLayer) -> String {
        return extractedFunc(mpLayer)
    }
    fileprivate func extractedFunc(_ mpLayer: MPLayer) -> String {
        switch mpLayer {
        case .TILE_LAYER:
            return Constants.LayerIDs.tileLayer
        case .MARKER_LAYER:
            return Constants.LayerIDs.markerLayer
        case .MARKER_NO_COLLISION_LAYER:
            return Constants.LayerIDs.markerNoCollisionLayer
        case .POLYGON_FILL_LAYER:
            return Constants.LayerIDs.polygonFillLayer
        case .POLYGON_LINE_LAYER:
            return Constants.LayerIDs.polygonLineLayer
        case .MODEL_2D_LAYER:
            return Constants.LayerIDs.model2DLayer
        case .ACCURACY_CIRCLE_LAYER:
            return Constants.LayerIDs.circleLayer
        case .BLUEDOT_LAYER:
            return Constants.LayerIDs.blueDotLayer
        }
    }
}

/**
 *
 * The layers used to render MapsIndoors content on Mapbox
 * TILE_LAYER represents the base layer on which all tiles are rendered
 * MARKER_LAYER represents the marker layer, which is a `SymbolLayer` on which all tiles are rendered
 * POLYGON_FILL_LAYER represents the lines that are typically filled,  it is a `FillLayer`
 * POLYGON_LINE_LAYER represents the lines that are typically stroked,  it is a `LineLayer`
 * MODEL_2D_LAYER represents the 2D Models it is a `SymbolLayer`
 * ACCURACY_CIRCLE_LAYER represents the accuracy circle around the blue dot, it is a `CircleLayer`
 * BLUEDOT_LAYER represents the blue dot, it is a `SymbolLayer`
 *
 */

@objc public enum MPLayer: Int {
    case TILE_LAYER
    case MARKER_LAYER
    case MARKER_NO_COLLISION_LAYER
    case POLYGON_FILL_LAYER
    case POLYGON_LINE_LAYER
    case MODEL_2D_LAYER
    case ACCURACY_CIRCLE_LAYER
    case BLUEDOT_LAYER
}
