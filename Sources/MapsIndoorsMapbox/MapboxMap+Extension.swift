import MapboxMaps
@_spi(Private) import MapsIndoorsCore

extension Constants {
    /// The Mapbox slot each MapsIndoors layer is assigned on creation — the single
    /// authority for slot assignment (SPEX-2354).
    ///
    /// On Mapbox v11 the slot, not the position in the layer array, decides render
    /// order across slots: a layer created without one escapes the slot system
    /// entirely and draws above everything — including the "top" slot, i.e. above
    /// the blue dot. Assigning slots here, at the one insertion point, means a new
    /// layer cannot be added without deciding its slot.
    ///
    /// Contract (mirrors the Android SDK): all MapsIndoors content, including the
    /// route, lives in "middle"; only the basemap-model clip layer lives in "top".
    /// The blue dot layers `MBPositionPresenter` creates dynamically are assigned
    /// "top" at their own creation site and are not managed here.
    static let slotForLayerId: [String: Slot] = [
        LayerIDs.tileLayer: "middle",
        LayerIDs.polygonFillLayer: "middle",
        LayerIDs.polygonLineLayer: "middle",
        LayerIDs.floorPlanFillLayer: "middle",
        LayerIDs.floorPlanLineLayer: "middle",
        LayerIDs.model2DLayer: "middle",
        LayerIDs.flatLabelsLayer: "middle",
        LayerIDs.lineLayer: "middle",
        LayerIDs.baseLineLayer: "middle",
        LayerIDs.animatedLineLayer: "middle",
        LayerIDs.stampLayer: "middle",
        LayerIDs.model3DLayer: "middle",
        LayerIDs.wallExtrusionLayer: "middle",
        LayerIDs.featureExtrusionLayer: "middle",
        LayerIDs.model2DElevatedLayer: "middle",
        LayerIDs.markerLayer: "middle",
        LayerIDs.markerNoCollisionLayer: "middle",
        LayerIDs.graphicLabelsLayer: "middle",
        LayerIDs.routeMarkerLayer: "middle",
        LayerIDs.clippingLayer: "top",
    ]
}

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

        // Wall extrusion layer
        let wallExtrusionLayer = FillExtrusionLayer(id: Constants.LayerIDs.wallExtrusionLayer, source: Constants.SourceIDs.geoJsonSourceWalls)

        // Feature extrusion layer
        let featureExtrusionLayer = FillExtrusionLayer(id: Constants.LayerIDs.featureExtrusionLayer, source: Constants.SourceIDs.geoJsonSourceExtrusions)

        let routeAnimatedLayer = LineLayer(id: Constants.LayerIDs.animatedLineLayer, source: Constants.SourceIDs.animatedLineSource)

        let routeLineLayer = LineLayer(id: Constants.LayerIDs.lineLayer, source: Constants.SourceIDs.lineSource)

        let routeBaseLayer = LineLayer(id: Constants.LayerIDs.baseLineLayer, source: Constants.SourceIDs.lineSource)

        // Repeating stamp (arrow / custom icon) along the route line, placed on the same line source.
        let routeStampLayer = SymbolLayer(id: Constants.LayerIDs.stampLayer, source: Constants.SourceIDs.lineSource)

        let routeMarkerLayer = SymbolLayer(id: Constants.LayerIDs.routeMarkerLayer, source: Constants.SourceIDs.routeMarkerSource)

        var clipLayer = ClipLayer(id: Constants.LayerIDs.clippingLayer, source: Constants.SourceIDs.clippingSource)
        clipLayer.clipLayerTypes = .constant([.model])
        clipLayer.clipLayerScope = .constant(["basemap"])

        // Sorted (first is bottom-most layer)
        let layersInAscendingOrder =
            [
                tileLayer,
                polygonFillLayer,
                polygonLineLayer,
                floorPlanFillLayer,
                floorPlanLineLayer,
                model2DLayer,
                flatLabelsLayer,
                routeLineLayer,
                routeBaseLayer,
                routeAnimatedLayer,
                routeStampLayer,
                model3DLayer,
                wallExtrusionLayer,
                featureExtrusionLayer,
                model2DElevatedLayer,
                markerLayer,
                markerNonCollisionlayer,
                graphicLabelsLayer,
                routeMarkerLayer,
                clipLayer,
            ] as [Layer]

        // The position reference is tracked per slot and only over layers confirmed
        // present: a `.above` reference into another slot is undefined behavior, and
        // a reference to a layer whose add failed would throw for every later layer,
        // cascading one failure into a mostly-empty style.
        var lastLayerIdBySlot: [String: String] = [:]
        for (index, var layer) in layersInAscendingOrder.enumerated() {
            if let slot = Constants.slotForLayerId[layer.id] {
                layer.slot = slot
            } else {
                // Still add the layer so content is never dropped in production, but
                // fail loudly in debug: it will render above ALL slots, incl. the blue dot.
                MPLog.mapbox.error("MapsIndoors layer '\(layer.id)' has no entry in Constants.slotForLayerId — a slotless layer renders above every slot (SPEX-2354).")
                assertionFailure("Missing slot contract entry for layer '\(layer.id)'")
            }
            let slotKey = layer.slot?.rawValue ?? ""
            do {
                if layerExists(withId: layer.id) == false {
                    if let prevId = lastLayerIdBySlot[slotKey] {
                        // Position above the preceding same-slot layer so restored layers
                        // land in the correct ascending order, not at the slot's top.
                        try addPersistentLayer(layer, layerPosition: .above(prevId))
                    } else if let nextExistingSameSlotId = layersInAscendingOrder[(index + 1)...]
                        .first(where: { Constants.slotForLayerId[$0.id]?.rawValue == slotKey && layerExists(withId: $0.id) })?.id {
                        // No same-slot layer below this one is present yet, but a later one
                        // already exists — insert below it, or an unpositioned add would land
                        // at the slot's top, covering everything (e.g. a re-added TILE_LAYER
                        // over the polygons/labels above it). Mirrors MBTileProvider's tile re-add.
                        try addPersistentLayer(layer, layerPosition: .below(nextExistingSameSlotId))
                    } else {
                        try addPersistentLayer(layer)
                    }
                } else if let slot = layer.slot, layerProperty(for: layer.id, property: "slot").value as? String != slot.rawValue {
                    // Repair path: the layer survived from an earlier style (persistent
                    // layers are re-added by Mapbox on style switches) or predates slot
                    // assignment — re-assert its contract slot rather than trusting it.
                    // Write only on mismatch: this runs on every map-setup pass.
                    try setLayerProperty(for: layer.id, property: "slot", value: slot.rawValue)
                }
            } catch {
                MPLog.mapbox.error("Failed to add or repair MapsIndoors layer '\(layer.id)': \(error.localizedDescription)")
            }
            if layerExists(withId: layer.id) {
                lastLayerIdBySlot[slotKey] = layer.id
            }
        }
    }
}
