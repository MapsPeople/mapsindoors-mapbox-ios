import Combine
import Foundation
@_spi(Experimental) import MapboxMaps
@_spi(Private) @preconcurrency import MapsIndoorsCore
import UIKit

private class InfoWindowTapRecognizer: UITapGestureRecognizer {
    var modelId = String()
}

class MBRenderer {
    /// The scale of an object relative to being zoomed out to zoom level 1 (from zoom level 22) 1/(2^22)
    static let zoom22Scale: Double = 1 / pow(2, 22)

    private weak var map: MapboxMap?
    private var _geoJsonSource: GeoJSONSource?
    private var _geometryGeoJsonSource: GeoJSONSource?
    private var _geoJsonSourceNoCollision: GeoJSONSource?
    private var _model3dGeoJsonSource: GeoJSONSource?
    private var _extrusionGeoJsonSource: GeoJSONSource?
    private var _wallsGeoJsonSource: GeoJSONSource?
    private var _clippingSource: GeoJSONSource?
    private weak var mapView: MapView?

    private var _lastModels = Set<AnyHashable>()
    private var lock = UnfairLock()

    // Dictionary to store created info windows
    private var infoWindows = MPThreadSafeDictionary<String, ViewAnnotation>()

    private weak var provider: MapBoxProvider?

    private var onImageUnusedCancelable: Cancelable?

    init(mapView: MapView?, provider: MapBoxProvider) {
        map = mapView?.mapboxMap
        self.provider = provider
        self.mapView = mapView

        onImageUnusedCancelable = map?.onStyleImageRemoveUnused.observe { [weak self] image in
            Task { @MainActor [weak self] in
                try self?.map?.removeImage(withId: image.imageId)
            }
        }

        map?.addMapsIndoorsLayers()

        do {
            try setupGeoJsonSource()
            try configureFlatLabelsLayer()
            try configureGraphicLabelsLayer()
            try configureMarkerLayer(layerId: Constants.LayerIDs.markerLayer)
            try configureMarkerLayer(layerId: Constants.LayerIDs.markerNoCollisionLayer)
            try configurePolygonLayers()
            try configureFloorPlanLayer()
            try configure2DModelLayer()
            try configure2DModelElevatedLayer()
            try configure3DModelLayer()
            try configureWallExtrusionLayer()
            try configureFeatureExtrusionLayer()
        } catch {
            MPLog.mapbox.error("Error setting up some layer/source: \(error.localizedDescription)")
        }

        configureForCollisionHandling(overlap: collisionHandling)
    }

    private func setupGeoJsonSource() throws {
        _geoJsonSource = GeoJSONSource(id: Constants.SourceIDs.geoJsonSource)
        _geoJsonSource?.data = nil
        _geoJsonSource?.tolerance = 0.2
        try map?.addSource(_geoJsonSource!)

        _geoJsonSourceNoCollision = GeoJSONSource(id: Constants.SourceIDs.geoJsonNoCollisionSource)
        _geoJsonSourceNoCollision?.data = nil
        _geoJsonSourceNoCollision?.tolerance = 0.2
        try map?.addSource(_geoJsonSourceNoCollision!)

        _geometryGeoJsonSource = GeoJSONSource(id: Constants.SourceIDs.geoJsonGeometrySource)
        _geometryGeoJsonSource?.data = nil
        _geometryGeoJsonSource?.tolerance = 0.2
        try map?.addSource(_geometryGeoJsonSource!)

        _model3dGeoJsonSource = GeoJSONSource(id: Constants.SourceIDs.geoJsonSource3dModels)
        _model3dGeoJsonSource?.data = nil
        _model3dGeoJsonSource?.tolerance = 0.5
        try map?.addSource(_model3dGeoJsonSource!)

        _extrusionGeoJsonSource = GeoJSONSource(id: Constants.SourceIDs.geoJsonSourceExtrusions)
        _extrusionGeoJsonSource?.data = nil
        _extrusionGeoJsonSource?.tolerance = 0.2
        try map?.addSource(_extrusionGeoJsonSource!)

        _wallsGeoJsonSource = GeoJSONSource(id: Constants.SourceIDs.geoJsonSourceWalls)
        _wallsGeoJsonSource?.data = nil
        _wallsGeoJsonSource?.tolerance = 0.2
        try map?.addSource(_wallsGeoJsonSource!)
        
        _clippingSource = GeoJSONSource(id: Constants.SourceIDs.clippingSource)
        try map?.addSource(_clippingSource!)
    }

    // MARK: Layers: adding and setting properties

    private func configureMarkerLayer(layerId: String) throws {
        try map?.updateLayer(withId: layerId, type: SymbolLayer.self) { layerUpdate in
            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.marker.rawValue }
            }

            layerUpdate.iconImage = .expression(Exp(.switchCase) {
                Exp(.eq) {
                    Exp(.get) { Key.hasImage.rawValue }
                    true
                }
                Exp(.get) { Key.markerId.rawValue }
                ""
            })
            layerUpdate.iconAnchor = .expression(Exp(.get) { Key.markerIconPlacement.rawValue })

            // Only set the text if it's a floating label
            layerUpdate.textField = .expression(Exp(.switchCase) {
                Exp(.eq) {
                    Exp(.get) { Key.labelType.rawValue }
                    Exp(.literal) { MPLabelType.floating.rawValue }
                }
                Exp(.get) { Key.markerLabel.rawValue }
                ""
            })

            layerUpdate.textAnchor = .expression(Exp(.get) { Key.labelAnchor.rawValue })
            layerUpdate.textJustify = .constant(TextJustify.left)
            layerUpdate.textOffset = .expression(Exp(.get) { Key.labelOffset.rawValue })
            layerUpdate.symbolSortKey = .expression(Exp(.subtract) { Exp(.get) { Key.markerGeometryArea.rawValue } })
            layerUpdate.textMaxWidth = .expression(Exp(.get) { Key.labelMaxWidth.rawValue })
            layerUpdate.textFont = .constant(["Open Sans Bold", "Arial Unicode MS Regular", "Arial Unicode MS Bold"])
            layerUpdate.textLetterSpacing = .constant(-0.01)
            layerUpdate.slot = .middle
            layerUpdate.symbolZElevate = .constant(true)

            // text styling
            layerUpdate.textSize = .expression(Exp(.get) { Key.labelSize.rawValue })
            layerUpdate.textColor = .expression(Exp(.get) { Key.labelColor.rawValue })
            layerUpdate.textOpacity = .expression(Exp(.get) { Key.labelOpacity.rawValue })
            layerUpdate.textHaloColor = .expression(Exp(.get) { Key.labelHaloColor.rawValue })
            layerUpdate.textHaloWidth = .expression(Exp(.get) { Key.labelHaloWidth.rawValue })
            layerUpdate.textHaloBlur = .expression(Exp(.get) { Key.labelHaloBlur.rawValue })
        }
    }

    private func configureFlatLabelsLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.flatLabelsLayer, type: SymbolLayer.self) { layerUpdate in
            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.labelType.rawValue }
                Exp(.literal) { MPLabelType.flat.rawValue }
            }

            layerUpdate.textField = .expression(Exp(.get) { Key.markerLabel.rawValue })
            layerUpdate.textAnchor = .constant(TextAnchor.center)
            layerUpdate.textJustify = .constant(TextJustify.center)
            layerUpdate.symbolSortKey = .expression(Exp(.subtract) { Exp(.get) { Key.markerGeometryArea.rawValue } })
            layerUpdate.textMaxWidth = .expression(Exp(.get) { Key.labelMaxWidth.rawValue })

            layerUpdate.textColor = .expression(Exp(.get) { Key.labelColor.rawValue })
            layerUpdate.textOpacity = .expression(Exp(.get) { Key.labelOpacity.rawValue })
            layerUpdate.textHaloColor = .expression(Exp(.get) { Key.labelHaloColor.rawValue })
            layerUpdate.textHaloWidth = .expression(Exp(.get) { Key.labelHaloWidth.rawValue })
            layerUpdate.textHaloBlur = .expression(Exp(.get) { Key.labelHaloBlur.rawValue })

            layerUpdate.textFont = .constant(["Open Sans Bold", "Arial Unicode MS Regular"])
            layerUpdate.textLetterSpacing = .constant(-0.01)

            layerUpdate.iconAllowOverlap = .constant(true)
            layerUpdate.textAllowOverlap = .constant(true)
            layerUpdate.iconOptional = .constant(false)
            layerUpdate.textOptional = .constant(false)
            layerUpdate.textPitchAlignment = .constant(.map)
            layerUpdate.textRotationAlignment = .constant(.map)
            layerUpdate.symbolPlacement = .constant(.point)

            layerUpdate.textRotate = .expression(Exp(.get) { Key.labelBearing.rawValue })

            layerUpdate.slot = .middle

            let stops: [Double: Exp] = [
                1: Exp(.product) {
                    Exp(.literal) { MBRenderer.zoom22Scale }
                    Exp(.get) { Key.labelSize.rawValue }
                },
                22: Exp(.product) {
                    Exp(.literal) { 1 }
                    Exp(.get) { Key.labelSize.rawValue }
                },
                23: Exp(.product) {
                    Exp(.literal) { 2 }
                    Exp(.get) { Key.labelSize.rawValue }
                },
                24: Exp(.product) {
                    Exp(.literal) { 4 }
                    Exp(.get) { Key.labelSize.rawValue }
                },
                25: Exp(.product) {
                    Exp(.literal) { 8 }
                    Exp(.get) { Key.labelSize.rawValue }
                }
            ]

            layerUpdate.textSize = .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 2 }
                    Exp(.zoom)
                    stops
                }
            )
        }
    }

    private func configureGraphicLabelsLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.graphicLabelsLayer, type: SymbolLayer.self) { layerUpdate in
            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.labelType.rawValue }
                Exp(.literal) { MPLabelType.graphic.rawValue }
            }

            layerUpdate.iconImage = .expression(Exp(.switchCase) {
                Exp(.eq) {
                    Exp(.get) { Key.hasImage.rawValue }
                    true
                }
                Exp(.get) { Key.labelGraphicId.rawValue }
                ""
            })

            layerUpdate.textField = .expression(Exp(.get) { Key.markerLabel.rawValue })
            layerUpdate.textAnchor = .constant(TextAnchor.center)
            layerUpdate.textJustify = .constant(TextJustify.center)
            layerUpdate.symbolSortKey = .expression(Exp(.subtract) { Exp(.get) { Key.markerGeometryArea.rawValue } })
            layerUpdate.textMaxWidth = .expression(Exp(.get) { Key.labelMaxWidth.rawValue })

            layerUpdate.textSize = .expression(Exp(.get) { Key.labelSize.rawValue })
            layerUpdate.textColor = .expression(Exp(.get) { Key.labelColor.rawValue })
            layerUpdate.textOpacity = .expression(Exp(.get) { Key.labelOpacity.rawValue })
            layerUpdate.textHaloColor = .expression(Exp(.get) { Key.labelHaloColor.rawValue })
            layerUpdate.textHaloWidth = .expression(Exp(.get) { Key.labelHaloWidth.rawValue })
            layerUpdate.textHaloBlur = .expression(Exp(.get) { Key.labelHaloBlur.rawValue })

            layerUpdate.textFont = .constant(["Open Sans Bold", "Arial Unicode MS Regular"])
            layerUpdate.textLetterSpacing = .constant(-0.01)

            layerUpdate.symbolPlacement = .constant(.point)

            layerUpdate.iconTextFit = .constant(.both)
            layerUpdate.iconAllowOverlap = .constant(true)
            layerUpdate.textAllowOverlap = .constant(true)
            layerUpdate.iconOptional = .constant(false)
            layerUpdate.textOptional = .constant(false)
            layerUpdate.iconIgnorePlacement = .constant(false)
            layerUpdate.textIgnorePlacement = .constant(false)
        }
    }

    private func configurePolygonLayers() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.polygonFillLayer, type: FillLayer.self) { layerUpdate in
            layerUpdate.fillColor = .expression(Exp(.get) { Key.polygonFillcolor.rawValue })
            layerUpdate.fillOpacity = .expression(Exp(.get) { Key.polygonFillOpacity.rawValue })
            layerUpdate.fillSortKey = .expression(Exp(.subtract) { Exp(.get) { Key.polygonArea.rawValue } })
            layerUpdate.slot = .middle
            layerUpdate.filter = Exp(.any) {
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.polygon.rawValue }
                }
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.model2d.rawValue }
                }
            }
        }

        try map?.updateLayer(withId: Constants.LayerIDs.polygonLineLayer, type: LineLayer.self) { layerUpdate in
            layerUpdate.lineColor = .expression(Exp(.get) { Key.polygonStrokeColor.rawValue })
            layerUpdate.lineOpacity = .expression(Exp(.get) { Key.polygonStrokeOpacity.rawValue })
            layerUpdate.lineWidth = .expression(Exp(.get) { Key.polygonStrokeWidth.rawValue })
            layerUpdate.lineJoin = .constant(.round)
            layerUpdate.slot = .middle
            layerUpdate.filter = Exp(.any) {
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.polygon.rawValue }
                }
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.model2d.rawValue }
                }
            }
        }
    }

    private func configureFloorPlanLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.floorPlanFillLayer, type: FillLayer.self) { layerUpdate in
            layerUpdate.fillColor = .expression(Exp(.get) { Key.floorPlanFillColor.rawValue })
            layerUpdate.fillOpacity = .expression(Exp(.get) { Key.floorPlanFillOpacity.rawValue })
            layerUpdate.slot = .middle
            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.floorplan.rawValue }
            }
        }

        try map?.updateLayer(withId: Constants.LayerIDs.floorPlanLineLayer, type: LineLayer.self) { layerUpdate in
            layerUpdate.lineColor = .expression(Exp(.get) { Key.floorPlanStrokeColor.rawValue })
            layerUpdate.lineOpacity = .expression(Exp(.get) { Key.floorPlanStrokeOpacity.rawValue })
            layerUpdate.lineWidth = .expression(Exp(.get) { Key.floorPlanStrokeWidth.rawValue })
            layerUpdate.lineJoin = .constant(.round)
            layerUpdate.slot = .middle
            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.floorplan.rawValue }
            }
        }
    }

    private func configure2DModelLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.model2DLayer, type: SymbolLayer.self) { layerUpdate in
            layerUpdate.iconAllowOverlap = .constant(true)
            layerUpdate.textAllowOverlap = .constant(true)
            layerUpdate.iconImage = .expression(Exp(.get) { Key.model2dId.rawValue })
            layerUpdate.iconRotate = .expression(Exp(.get) { Key.model2dBearing.rawValue })
            layerUpdate.iconPitchAlignment = .constant(.map)
            layerUpdate.iconRotationAlignment = .constant(.map)
            layerUpdate.slot = .middle

            let stops: [Double: Exp] = [
                1: Exp(.product) {
                    Exp(.literal) { MBRenderer.zoom22Scale }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                22: Exp(.product) {
                    Exp(.literal) { 1 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                23: Exp(.product) {
                    Exp(.literal) { 2 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                24: Exp(.product) {
                    Exp(.literal) { 4 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                25: Exp(.product) {
                    Exp(.literal) { 8 }
                    Exp(.get) { Key.model2DScale.rawValue }
                }
            ]

            layerUpdate.iconSize = .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 2 }
                    Exp(.zoom)
                    stops
                }
            )

            layerUpdate.filter = Exp(.all) {
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.model2d.rawValue }
                }
                Exp(.eq) {
                    Exp(.get) { Key.model2DIsElevated.rawValue }
                    false
                }
            }
        }
    }
    
    private func configure2DModelElevatedLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.model2DElevatedLayer, type: SymbolLayer.self) { layerUpdate in
            layerUpdate.iconAllowOverlap = .constant(true)
            layerUpdate.textAllowOverlap = .constant(true)
            layerUpdate.iconImage = .expression(Exp(.get) { Key.model2dId.rawValue })
            layerUpdate.iconRotate = .expression(Exp(.get) { Key.model2dBearing.rawValue })
            layerUpdate.iconPitchAlignment = .constant(.map)
            layerUpdate.iconRotationAlignment = .constant(.map)
            layerUpdate.slot = .middle

            layerUpdate.symbolZElevate = .constant(true)
            
            let stops: [Double: Exp] = [
                1: Exp(.product) {
                    Exp(.literal) { MBRenderer.zoom22Scale }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                22: Exp(.product) {
                    Exp(.literal) { 1 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                23: Exp(.product) {
                    Exp(.literal) { 2 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                24: Exp(.product) {
                    Exp(.literal) { 4 }
                    Exp(.get) { Key.model2DScale.rawValue }
                },
                25: Exp(.product) {
                    Exp(.literal) { 8 }
                    Exp(.get) { Key.model2DScale.rawValue }
                }
            ]

            layerUpdate.iconSize = .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 2 }
                    Exp(.zoom)
                    stops
                }
            )

            layerUpdate.filter = Exp(.all) {
                Exp(.eq) {
                    Exp(.get) { Key.type.rawValue }
                    Exp(.literal) { MPRenderedFeatureType.model2d.rawValue }
                }
                Exp(.eq) {
                    Exp(.get) { Key.model2DIsElevated.rawValue}
                    true
                }
            }
        }
    }

    private func configure3DModelLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.model3DLayer, type: ModelLayer.self) { layerUpdate in
            layerUpdate.modelId = .expression(Exp(.get) { Key.model3dId.rawValue })
            layerUpdate.modelScale = .expression(Exp(.get) { Key.model3DScale.rawValue })
            layerUpdate.modelRotation = .expression(Exp(.get) { Key.model3DRotation.rawValue })
            layerUpdate.modelType = .constant(.common3d)
            layerUpdate.slot = .middle
        }
    }

    private func configureWallExtrusionLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.wallExtrusionLayer, type: FillExtrusionLayer.self) { layerUpdate in
            layerUpdate.fillExtrusionColor = .expression(Exp(.get) { Key.wallExtrusionColor.rawValue })
            layerUpdate.fillExtrusionHeight = .expression(Exp(.get) { Key.wallExtrusionHeight.rawValue })
            layerUpdate.slot = .middle
        }
    }

    private func configureFeatureExtrusionLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.featureExtrusionLayer, type: FillExtrusionLayer.self) { layerUpdate in
            layerUpdate.fillExtrusionColor = .expression(Exp(.get) { Key.featureExtrusionColor.rawValue })
            layerUpdate.fillExtrusionHeight = .expression(Exp(.get) { Key.featureExtrusionHeight.rawValue })
            layerUpdate.slot = .middle
        }
    }

    var isFeatureExtrusionsEnabled = false

    var isWallExtrusionsEnabled = false

    var is2dModelsEnabled = false

    var isFloorPlanEnabled = false

    var featureExtrusionOpacity: Double = 0 {
        didSet {
            if oldValue != featureExtrusionOpacity {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try map?.updateLayer(withId: Constants.LayerIDs.featureExtrusionLayer, type: FillExtrusionLayer.self) { layer in
                            layer.fillExtrusionOpacity = .constant(self.featureExtrusionOpacity)
                        }
                    } catch {}
                }
            }
        }
    }

    var wallExtrusionOpacity: Double = 0 {
        didSet {
            if oldValue != wallExtrusionOpacity {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try map?.updateLayer(withId: Constants.LayerIDs.wallExtrusionLayer, type: FillExtrusionLayer.self) { layer in
                            layer.fillExtrusionOpacity = .constant(self.wallExtrusionOpacity)
                        }
                    } catch {}
                }
            }
        }
    }

    var collisionHandling: MPCollisionHandling = .allowOverLap {
        didSet {
            if oldValue != collisionHandling {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    configureForCollisionHandling(overlap: collisionHandling)
                }
            }
        }
    }

    // MARK: Collision handling

    struct MBOverlapSettings {
        var iconAllowOverlap: Bool
        var textAllowOverlap: Bool
        var iconOptional: Bool
        var textOptional: Bool
    }

    private func configureForCollisionHandling(overlap: MPCollisionHandling) {
        let settings =
            switch overlap {
            case .removeIconFirst:
                MBOverlapSettings(iconAllowOverlap: false, textAllowOverlap: false, iconOptional: true, textOptional: false)
            case .removeLabelFirst:
                MBOverlapSettings(iconAllowOverlap: false, textAllowOverlap: false, iconOptional: false, textOptional: true)
            case .removeIconAndLabel:
                MBOverlapSettings(iconAllowOverlap: false, textAllowOverlap: false, iconOptional: false, textOptional: false)
            case .allowOverLap:
                MBOverlapSettings(iconAllowOverlap: true, textAllowOverlap: true, iconOptional: false, textOptional: false)
            @unknown default:
                MBOverlapSettings(iconAllowOverlap: true, textAllowOverlap: true, iconOptional: false, textOptional: false)  // As default .allowOverlap
            }

        do {
            try updateLayerOverlapSettings(settings)
        } catch {
            MPLog.mapbox.error("Error updating layer: \(error.localizedDescription)")
        }
    }

    private func updateLayerOverlapSettings(_ settings: MBOverlapSettings) throws {
        try map?.updateLayer(withId: Constants.LayerIDs.markerLayer, type: SymbolLayer.self) { layer in
            layer.iconAllowOverlap = .constant(settings.iconAllowOverlap)
            layer.textAllowOverlap = .constant(settings.textAllowOverlap)
            layer.iconOptional = .constant(settings.iconOptional)
            layer.textOptional = .constant(settings.textOptional)
        }

        try map?.updateLayer(withId: Constants.LayerIDs.markerNoCollisionLayer, type: SymbolLayer.self) { layer in
            layer.iconAllowOverlap = .constant(true)
            layer.textAllowOverlap = .constant(true)
            layer.iconOptional = .constant(false)
            layer.textOptional = .constant(false)
        }
    }

    // MARK: Rendering and updating source

    var customInfoWindow: MPCustomInfoWindow?
    private static let infoWindowPrefix = "viewAnnotation"

    private func setupInfoWindowTapRecognizer(infoWindowView: UIView, modelId: String) {
        let recognizer = InfoWindowTapRecognizer(target: self, action: #selector(onInfoWindowTapped(sender:)))
        recognizer.modelId = modelId
        infoWindowView.addGestureRecognizer(recognizer)
    }

    @objc private func onInfoWindowTapped(sender: InfoWindowTapRecognizer) {
        provider?.onInfoWindowTapped(locationId: sender.modelId)
    }

    private func removeOldModels(models: [any MPViewModel]) {
        let modelsNoLongerInView = _lastModels.subtracting(models as! [AnyHashable])
        for model in modelsNoLongerInView {
            if let viewModel = model as? (any MPViewModel) {
                removeInfoWindow(for: viewModel)
            }
        }
        _lastModels.removeAll(keepingCapacity: false)
    }

    let d = DispatchQueue(label: "mdf", qos: .userInteractive)

    // LRU cache for storing computed GeoJSON -> Mapbox Feature results, as a heuristic to optimize the rendering pipeline's performance.
//    private var modelCache = LRUCache<String, ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])>(countLimit: 5_000)
    func render(models: [any MPViewModel]) async throws {
        try Task.checkCancellation()
        let startTime = DispatchTime.now()
        d.async { self.removeOldModels(models: models) }
        try Task.checkCancellation()
        let models = await withTaskGroup(of: ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature]).self) { group -> [([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])] in
            for model in models {
                _ = group.addTaskUnlessCancelled(priority: .userInitiated) { [weak self] in
                    guard let self else { return ([], [], [], [], [], []) }

                    d.async { _ = self._lastModels.insert(model) }
                    updateInfoWindow(for: model)

//                    let md5 = model.md5
//                    if let cacheHit = modelCache[md5] {
//                        return cacheHit
//                    }

                    updateImage(for: model)
                    update2DModel(for: model)

                    var features = [Feature]()
                    var featuresGeometry = [Feature]()
                    var featuresNonCollision = [Feature]()
                    var featuresExtrusions = [Feature]()
                    var featuresWalls = [Feature]()
                    var features3DModels = [Feature]()

                    if let marker = model.markerFeature {
                        if model.marker?.properties[.isCollidable] as? Bool ?? true == false {
                            featuresNonCollision.append(marker)
                            features.append(marker)
                        } else {
                            features.append(marker)
                        }
                    }

                    if let polygon = model.polygonFeature {
                        featuresGeometry.append(polygon)
                    }

                    if isFloorPlanEnabled, let floorPlan = model.floorPlanFeature {
                        featuresGeometry.append(floorPlan)
                    }

                    if is2dModelsEnabled, let model2D = model.model2DFeature,
                       let model2DGeometry = model.model2DGeometryFeature {
                        features.append(model2D)
                        featuresGeometry.append(model2DGeometry)
                    }

                    if let model3D = model.model3DFeature {
                        features3DModels.append(model3D)
                    }

                    if isWallExtrusionsEnabled, let wallExtrusionLayer = model.wallExtrusionFeature {
                        featuresWalls.append(wallExtrusionLayer)
                    }

                    if isFeatureExtrusionsEnabled, let featureExtrusionLayer = model.featureExtrusionFeature {
                        featuresExtrusions.append(featureExtrusionLayer)
                    }

                    let result = (features, featuresGeometry, featuresNonCollision, featuresExtrusions, featuresWalls, features3DModels)

//                    modelCache[md5] = result

                    return result
                }
            }

            let res = await group.reduce(into: [([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])]()) { result, feature in result.append(feature) }

            return res
        }

        try Task.checkCancellation()

        var features = [Feature]()
        var featuresGeometry = [Feature]()
        var featuresNonCollision = [Feature]()
        var featuresExtrusions = [Feature]()
        var featuresWalls = [Feature]()
        var features3DModels = [Feature]()
        features.reserveCapacity(models.count)
        featuresGeometry.reserveCapacity(models.count)
        featuresNonCollision.reserveCapacity(models.count)
        featuresExtrusions.reserveCapacity(models.count)
        featuresWalls.reserveCapacity(models.count)
        features3DModels.reserveCapacity(models.count)

        try Task.checkCancellation()

        for x in models {
            features.append(contentsOf: x.0)
            featuresGeometry.append(contentsOf: x.1)
            featuresNonCollision.append(contentsOf: x.2)
            featuresExtrusions.append(contentsOf: x.3)
            featuresWalls.append(contentsOf: x.4)
            features3DModels.append(contentsOf: x.5)
        }

        let elapsedTimeInNanoSec = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let elapsedTimeInMilliSec = Double(elapsedTimeInNanoSec) / 1_000_000_000
        MPLog.mapbox.measure("ViewModel to Feature", timeMs: elapsedTimeInMilliSec)

        try Task.checkCancellation()

        try updateGeoJSONSource(features: features, geometryFeatures: featuresGeometry, nonCollisionFeatures: featuresNonCollision, featuresExtrusions: featuresExtrusions, featuresWalls: featuresWalls, features3DModels: features3DModels)
    }

    private func removeInfoWindow(for model: any MPViewModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let infoWindow = infoWindows[model.id] {
                infoWindow.remove()
                infoWindows.removeValue(forKey: model.id)
            }
        }
    }

    private func updateInfoWindow(for model: any MPViewModel) {
        if model.showInfoWindow {
            if let point = model.marker?.geometry.coordinates as? MPPoint, let location = MPMapsIndoors.shared.locationWith(locationId: model.id) {
                createOrUpdateInfoWindow(for: model, at: point, location: location)
            }
        } else {
            removeInfoWindow(for: model)
        }
    }

    private func createOrUpdateInfoWindow(for model: any MPViewModel, at point: MPPoint, location: MPLocation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var yOffset = 0.0
            var xOffset = 0.0

            let respectDistance = 5.0

            // Based on icon placement and size, compute offsets for the info window
            if let icon = model.data[.icon] as? UIImage {
                if let iconPlacement = model.marker?.properties[.markerIconPlacement] as? String {
                    yOffset = (icon.size.height / 2) + respectDistance

                    switch iconPlacement {
                    case "bottom":
                        yOffset = icon.size.height + respectDistance
                    case "top":
                        yOffset = respectDistance
                    case "left":
                        xOffset = icon.size.width / 2
                    case "right":
                        xOffset = -(icon.size.width / 2)
                    case "center":
                        fallthrough
                    default:
                        break
                    }
                }
            }
            
            guard infoWindows[model.id] == nil else { return }
            
            if let infoWindowView = customInfoWindow?.infoWindowFor(location: location) {
                
                let view = ViewAnnotation(coordinate: point.coordinate, view: infoWindowView)
                
                // Ensure it is shown dispite anything else
                view.allowZElevate = true
                view.allowOverlap = true
                view.ignoreCameraPadding = true
                view.allowOverlapWithPuck = true
                
                // Mapbox will automatically adjust to the "best" anchor, depending on surroundings - but we just want to ensure it appears above the marker, and thus only provide that option.
                view.variableAnchors = [
                    ViewAnnotationAnchorConfig(anchor: .bottom, offsetX: xOffset, offsetY: yOffset)
                ]
                
                // Remember the view annotation
                infoWindows[model.id] = view
                
                // Add the view annotation to the map
                mapView?.viewAnnotations.add(view)
                setupInfoWindowTapRecognizer(infoWindowView: view.view, modelId: model.id)
            }
        }
    }

    private func updateImage(for model: any MPViewModel) {
        if let icon = model.data[.icon] as? UIImage, let id = model.marker?.id {
            map?.safeAddImage(image: icon, id: id)
        }

        if let graphicImage = model.data[.graphicLabelImage] as? UIImage,
           let id = model.marker?.properties[.labelGraphicId] as? String,
           let x = model.marker?.properties[.labelGraphicStretchX] as? [[Int]],
           let y = model.marker?.properties[.labelGraphicStretchY] as? [[Int]],
           let content = model.marker?.properties[.labelGraphicContent] as? [Int], content.count == 4 {
            map?.safeAddImage(image: graphicImage,
                              id: id,
                              stretchX: x.compactMap { ImageStretches(first: Float($0[0]), second: Float($0[1])) },
                              stretchY: y.compactMap { ImageStretches(first: Float($0[0]), second: Float($0[1])) },
                              content: ImageContent(left: Float(content[0]), top: Float(content[1]), right: Float(content[2]), bottom: Float(content[3])))
        }
    }

    private func update2DModel(for model: any MPViewModel) {
        if let model2D = model.data[.model2D] as? UIImage, let id = model.model2D?.id, is2dModelsEnabled {
            map?.safeAddImage(image: model2D, id: id)
        }
    }

    var enabled = true {
        didSet {
            print("enabled: \(String(enabled))")
        }
    }

    private func updateGeoJSONSource(features: [Feature], geometryFeatures: [Feature], nonCollisionFeatures: [Feature], featuresExtrusions: [Feature], featuresWalls: [Feature], features3DModels: [Feature]) throws {
        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSource, geoJSON: .featureCollection(FeatureCollection(features: features)).geoJSONObject)
        }

        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonGeometrySource, geoJSON: .featureCollection(FeatureCollection(features: geometryFeatures)).geoJSONObject)
        }

        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonNoCollisionSource, geoJSON: .featureCollection(FeatureCollection(features: nonCollisionFeatures)).geoJSONObject)
        }

        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSourceExtrusions, geoJSON: .featureCollection(FeatureCollection(features: featuresExtrusions)).geoJSONObject)
        }

        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSourceWalls, geoJSON: .featureCollection(FeatureCollection(features: featuresWalls)).geoJSONObject)
        }

        try Task.checkCancellation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSource3dModels, geoJSON: .featureCollection(FeatureCollection(features: features3DModels)).geoJSONObject)
        }
    }
}

// MARK: Extensions

/**
 We are extending the view model protocol with implementations for producing Mapbox 'Feature' objects.
 */
private extension MPViewModel {
    var md5: String {
        let id = id
        let markerHash = marker?.asString ?? ""
        let polygonHash = polygon?.asString ?? ""
        let floorPlanHash = floorPlanExtrusion?.asString ?? ""
        let model2DHash = model2D?.asString ?? ""
        let model3DHash = model3D?.asString ?? ""
        let wallHash = wallExtrusion?.asString ?? ""
        let featureHash = featureExtrusion?.asString ?? ""
        return (id + markerHash + polygonHash + floorPlanHash + model2DHash + model3DHash + wallHash + featureHash).md5
    }

    var markerFeature: Feature? {
        guard let marker else { return nil }
        let string = marker.toGeoJson()
        return parse(geojson: string)
    }

    var polygonFeature: Feature? {
        guard let polygon else { return nil }
        let string = polygon.toGeoJson()
        return parse(geojson: string)
    }

    var floorPlanFeature: Feature? {
        guard let floorPlan = floorPlanExtrusion else { return nil }
        let string = floorPlan.toGeoJson()
        return parse(geojson: string)
    }

    var model2DFeature: Feature? {
        guard let model2D else { return nil }
        let string = model2D.toGeoJson()
        return parse(geojson: string)
    }

    var model2DGeometryFeature: Feature? {
        guard let center = ((model2D?.geometry as? MPViewModelFeatureGeometry)?.coordinates as? MPPoint)?.coordinate,
              let bearing = model2D?.properties[.model2dBearing] as? Double,
              let width = model2D?.properties[.model2DWidth] as? Double,
              let height = model2D?.properties[.model2DHeight] as? Double else { return nil }

        let centerToCornerDist = hypot(width, height) / 2

        let a = width / 2
        let b = height / 2
        let c = hypot(a, b)

        let angle = acos((pow(c, 2) + pow(a, 2) - pow(b, 2)) / (2 * c * a)) * (180 / .pi)

        let pointA = center.computeOffset(distanceMeters: centerToCornerDist, heading: (90 - angle) + bearing)
        let pointB = center.computeOffset(distanceMeters: centerToCornerDist, heading: (90 + angle) + bearing)
        let pointC = center.computeOffset(distanceMeters: centerToCornerDist, heading: ((90 - angle) + 180) + bearing)
        let pointD = center.computeOffset(distanceMeters: centerToCornerDist, heading: ((90 + angle) + 180) + bearing)

        let geometry = Polygon([[pointA, pointB, pointC, pointD]])

        var feature = Feature(geometry: geometry)
        feature.identifier = .string(id)

        // For debugging, the model 2D bounding geometry can be rendered as a polygon feature - just increase opacity below
        feature.properties = JSONObject()
        feature.properties?[Key.polygonFillcolor.rawValue] = "#FF0000"
        feature.properties?[Key.polygonFillOpacity.rawValue] = 0.0
        feature.properties?[Key.polygonStrokeOpacity.rawValue] = 0.0
        feature.properties?[Key.polygonArea.rawValue] = JSONValue(width * height)
        feature.properties?[Key.type.rawValue] = "model2d"

        return feature
    }

    var model3DFeature: Feature? {
        guard let model3D else { return nil }
        let string = model3D.toGeoJson()
        return parse(geojson: string)
    }

    var wallExtrusionFeature: Feature? {
        guard let wallExtrusion else { return nil }
        let string = wallExtrusion.toGeoJson()
        return parse(geojson: string)
    }

    var featureExtrusionFeature: Feature? {
        guard let featureExtrusion else { return nil }
        let string = featureExtrusion.toGeoJson()
        return parse(geojson: string)
    }

    private func parse(geojson: String) -> Feature? {
        do {
            return try JSONDecoder().decode(Feature.self, from: geojson.data(using: .utf8)!)
        } catch {
            MPLog.mapbox.error("Error parsing data: \(error)")
        }
        return nil
    }
}

private extension CLLocationCoordinate2D {
    func computeOffset(distanceMeters: Double, heading: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6378137.0
        let distance = distanceMeters / earthRadius
        let heading = heading.radians
        let fromLat = latitude.radians
        let fromLng = longitude.radians
        let cosDistance = cos(distance)
        let sinDistance = sin(distance)
        let sinFromLat = sin(fromLat)
        let cosFromLat = cos(fromLat)
        let sinLat = cosDistance * sinFromLat + sinDistance * cosFromLat * cos(heading)
        let dLng = atan2(sinDistance * cosFromLat * sin(heading), cosDistance - sinFromLat * sinLat)
        return CLLocationCoordinate2D(latitude: asin(sinLat).degrees, longitude: (fromLng + dLng).degrees)
    }
}

private extension UIImage {
    func scaled(size: CGSize) -> UIImage? {
        guard size != .zero else { return nil }

        let rendererFormat = UIGraphicsImageRendererFormat.preferred()
        rendererFormat.opaque = false
        rendererFormat.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: rendererFormat)

        return renderer.image { _ in
            draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
    }
}

private extension MapboxMap {
    /// Call this to add/update image
    /// - Parameters:
    ///   - image: image/icon to be passed
    ///   - withId: Id with which to check/add to map style
    func safeAddImage(image: UIImage, id: String, stretchX: [ImageStretches]? = nil, stretchY: [ImageStretches]? = nil, content: ImageContent? = nil) {
        if Thread.isMainThread {
            do {
                if let stretchX, let stretchY, let content {
                    try addImage(image, id: id, stretchX: stretchX, stretchY: stretchY, content: content)
                } else {
                    try addImage(image, id: id)
                }
            } catch {
                MPLog.mapbox.error("Error adding/updating image: \(error.localizedDescription)")
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if let stretchX, let stretchY, let content {
                        try addImage(image, id: id, stretchX: stretchX, stretchY: stretchY, content: content)
                    } else {
                        try addImage(image, id: id)
                    }
                } catch {
                    MPLog.mapbox.error("Error adding/updating image: \(error.localizedDescription)")
                }
            }
        }
    }
}

private class UnfairLock {
    // https://swiftrocks.com/thread-safety-in-swift

    private var _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deallocate()
    }

    func locked<ReturnValue>(_ f: () throws -> ReturnValue) rethrows -> ReturnValue {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try f()
    }
}

// MARK: Temporarily here

/// The different positions to place label of an MPLocation on the map.
@objc enum MPLabelPosition: Int, Codable {
    /// Will place labels on top.
    case top

    /// Will place labels on bottom.
    case bottom

    /// Will place labels on left.
    case left

    /// Will place labels on right.
    case right
}

private extension LRUCache<String, ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])> {
    subscript(key: String) -> ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])? {
        get {
            value(forKey: key)
        }
        set {
            if let array = newValue {
                let stride = MemoryLayout<Feature>.stride
                let usedBytes = array.0.count * stride +
                    array.1.count * stride +
                    array.2.count * stride +
                    array.3.count * stride +
                    array.4.count * stride +
                    array.5.count * stride

                setValue(array, forKey: key, cost: usedBytes)
            } else {
                removeValue(forKey: key)
            }
        }
    }
}
