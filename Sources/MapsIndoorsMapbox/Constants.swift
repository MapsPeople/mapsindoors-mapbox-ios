//
//  Constants.swift
//  MapsIndoorsMapbox
//
//  Created by Frederik Hansen on 15/09/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation


struct Constants {
    
    struct LayerIDs {
        static let tileLayer = "TILE_LAYER"
        static let flatLabelsLayer = "FLAT_LABELS_LAYER"
        static let graphicLabelsLayer = "GRAPHIC_LABELS_LAYER"
        static let markerLayer = "MARKER_LAYER"
        static let markerNoCollisionLayer = "MARKER_NO_COLLISION_LAYER"
        static let polygonFillLayer = "POLYGON_FILL_LAYER"
        static let polygonLineLayer = "POLYGON_LINE_LAYER"
        static let floorPlanFillLayer = "FLOORPLAN_FILL_LAYER"
        static let floorPlanLineLayer = "FLOORPLAN_LINE_LAYER"
        static let model2DLayer = "MODEL_2D_LAYER"
        static let model3DLayer = "MODEL_3D_LAYER"
        static let circleLayer = "CIRCLE_LAYER"
        static let blueDotLayer = "BLUEDOT_LAYER"
        static let wallExtrusionLayer = "WALL_EXTRUSION_LAYER"
        static let featureExtrusionLayer = "FEATURE_EXTRUSION_LAYER"
        
        //Route rendering
        static let lineLayer = "ROUTE_POLYLINE_LAYER"
        static let animatedLineLayer = "ROUTE_ANIMATED_POLYLINE_LAYER"
        static let routeMarkerLayer = "ROUTE_MARKER_LAYER"
    }
    
    struct SourceIDs {
        static let tileSource = "TILE_SOURCE"
        static let geoJsonSource = "GEOJSON_SOURCE"
        static let geoJsonNoCollisionSource = "GEOJSON_NO_COLLISION_SOURCE"
        static let geoJsonSourceExtrusions = "GEOJSON_EXTRUSIONS_SOURCE"
        static let geoJsonSource3dModels = "GEOJSON_3DMODELS_SOURCE"
        static let circleSource = "CIRCLE_SOURCE"
        static let blueDotSource = "BLUEDOT_SOURCE"
        
        //Route rendering
        static let lineSource = "ROUTE_POLYLINE_SOURCE"
        static let animatedLineSource = "ROUTE_ANIMATED_POLYLINE_SOURCE"
        static let routeMarkerSource = "ROUTE_MARKER_SOURCE"
    }
    
    struct BlueDotProperties {
        static let iconKey = "ICON_KEY"
        static let dotProperty = "DOT_PROPERTY"
        static let dotIconId = "DOT_ICON_ID"
        static let headingProperty = "HEADING_PROPERTY"
        static let headingIconId = "HEADING_ICON_ID"
        
    }
}
