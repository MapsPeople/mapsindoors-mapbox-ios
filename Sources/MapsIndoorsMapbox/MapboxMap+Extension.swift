@_spi(Experimental) import MapboxMaps
@_spi(Private) import MapsIndoorsCore

extension MapboxMap {
    func addMapsIndoorsLayers() {
        // Tile
        let tileLayer = RasterLayer(id: Constants.LayerIDs.tileLayer, source: Constants.SourceIDs.tileSource)

        // Polygon
        let polygonFillLayer = FillLayer(id: Constants.LayerIDs.polygonFillLayer, source: Constants.SourceIDs.geoJsonGeometrySource)
        let polygonLineLayer = LineLayer(id: Constants.LayerIDs.polygonLineLayer, source: Constants.SourceIDs.geoJsonGeometrySource)

        // Floor Plan
        let floorPlanFillLayer = FillLayer(id: Constants.LayerIDs.floorPlanFillLayer, source: Constants.SourceIDs.geoJsonGeometrySource)
        let floorPlanLineLayer = LineLayer(id: Constants.LayerIDs.floorPlanLineLayer, source: Constants.SourceIDs.geoJsonGeometrySource)

        // Flat Labels
        let flatLabelsLayer = SymbolLayer(id: Constants.LayerIDs.flatLabelsLayer, source: Constants.SourceIDs.geoJsonSource)

        // Graphic Labels
        let graphicLabelsLayer = SymbolLayer(id: Constants.LayerIDs.graphicLabelsLayer, source: Constants.SourceIDs.geoJsonSource)

        // Markers
        let markerLayer = SymbolLayer(id: Constants.LayerIDs.markerLayer, source: Constants.SourceIDs.geoJsonSource)

        let markerNonCollisionlayer = SymbolLayer(id: Constants.LayerIDs.markerNoCollisionLayer, source: Constants.SourceIDs.geoJsonNoCollisionSource)

        // 2D Models
        let model2DLayer = SymbolLayer(id: Constants.LayerIDs.model2DLayer, source: Constants.SourceIDs.geoJsonSource)
        
        // 2D Models
        let model2DElevatedLayer = SymbolLayer(id: Constants.LayerIDs.model2DElevatedLayer, source: Constants.SourceIDs.geoJsonSource)

        // 3D Models
        let model3DLayer = ModelLayer(id: Constants.LayerIDs.model3DLayer, source: Constants.SourceIDs.geoJsonSource3dModels)

        // Circle
        let circleLayer = CircleLayer(id: Constants.LayerIDs.circleLayer, source: Constants.SourceIDs.blueDotSource)

        // Wall extrusion layer
        let wallExtrusionLayer = FillExtrusionLayer(id: Constants.LayerIDs.wallExtrusionLayer, source: Constants.SourceIDs.geoJsonSourceWalls)

        // Feature extrusion layer
        let featureExtrusionLayer = FillExtrusionLayer(id: Constants.LayerIDs.featureExtrusionLayer, source: Constants.SourceIDs.geoJsonSourceExtrusions)

        let blueDotLayer = SymbolLayer(id: Constants.LayerIDs.blueDotLayer, source: Constants.SourceIDs.blueDotSource)

        let routeAnimatedLayer = LineLayer(id: Constants.LayerIDs.animatedLineLayer, source: Constants.SourceIDs.animatedLineSource)

        let routeLineLayer = LineLayer(id: Constants.LayerIDs.lineLayer, source: Constants.SourceIDs.lineSource)

        let routeMarkerLayer = SymbolLayer(id: Constants.LayerIDs.routeMarkerLayer, source: Constants.SourceIDs.routeMarkerSource)
        
        var clipLayer = ClipLayer(id: Constants.LayerIDs.clippingLayer, source: Constants.SourceIDs.clippingSource)
        clipLayer.slot = .top
        clipLayer.clipLayerTypes = .constant([.model])
        clipLayer.clipLayerScope = .constant(["basemap"])
        
        // Sorted (first is bottom-most layer)
        let layersInAscendingOrder = [
            tileLayer,
            polygonFillLayer,
            polygonLineLayer,
            floorPlanFillLayer,
            floorPlanLineLayer,
            model2DLayer,
            flatLabelsLayer,
            routeLineLayer,
            routeAnimatedLayer,
            model3DLayer,
            wallExtrusionLayer,
            featureExtrusionLayer,
            model2DElevatedLayer,
            markerLayer,
            markerNonCollisionlayer,
            graphicLabelsLayer,
            circleLayer,
            blueDotLayer,
            routeMarkerLayer,
            clipLayer
        ] as [Layer]

        for layer in layersInAscendingOrder {
            do {
                if layerExists(withId: layer.id) == false {
                    try addPersistentLayer(layer)
                }
            } catch {
                MPLog.mapbox.debug(error.localizedDescription)
            }
        }
    }
}
