import Combine
import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore
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

    @MainActor private var _lastModels = Set<AnyHashable>()
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
                self?.imagesAdded.removeValue(forKey: image.imageId)
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

            layerUpdate.iconImage = .expression(
                Exp(.switchCase) {
                    Exp(.eq) {
                        Exp(.get) { Key.hasImage.rawValue }
                        true
                    }
                    Exp(.get) { Key.markerId.rawValue }
                    ""
                })
            layerUpdate.iconAnchor = .expression(Exp(.get) { Key.markerIconPlacement.rawValue })

            // Only set the text if it's a floating label
            layerUpdate.textField = .expression(
                Exp(.switchCase) {
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
                },
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

            layerUpdate.iconImage = .expression(
                Exp(.switchCase) {
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
                },
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
                },
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

            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.model3d.rawValue }
            }
        }
    }

    private func configureWallExtrusionLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.wallExtrusionLayer, type: FillExtrusionLayer.self) { layerUpdate in
            layerUpdate.fillExtrusionColor = .expression(Exp(.get) { Key.wallExtrusionColor.rawValue })
            layerUpdate.fillExtrusionHeight = .expression(Exp(.get) { Key.wallExtrusionHeight.rawValue })
            layerUpdate.slot = .middle

            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.wallExtrusion.rawValue }
            }
        }
    }

    private func configureFeatureExtrusionLayer() throws {
        try map?.updateLayer(withId: Constants.LayerIDs.featureExtrusionLayer, type: FillExtrusionLayer.self) { layerUpdate in
            layerUpdate.fillExtrusionColor = .expression(Exp(.get) { Key.featureExtrusionColor.rawValue })
            layerUpdate.fillExtrusionHeight = .expression(Exp(.get) { Key.featureExtrusionHeight.rawValue })
            layerUpdate.slot = .middle

            layerUpdate.filter = Exp(.eq) {
                Exp(.get) { Key.type.rawValue }
                Exp(.literal) { MPRenderedFeatureType.featureExtrusion.rawValue }
            }
        }
    }

    var isFeatureExtrusionsEnabled = false {
        didSet { if oldValue != isFeatureExtrusionsEnabled { modelCache.removeAll() } }
    }

    var isWallExtrusionsEnabled = false {
        didSet { if oldValue != isWallExtrusionsEnabled { modelCache.removeAll() } }
    }

    var is2dModelsEnabled = false {
        didSet { if oldValue != is2dModelsEnabled { modelCache.removeAll() } }
    }

    var isFloorPlanEnabled = false {
        didSet { if oldValue != isFloorPlanEnabled { modelCache.removeAll() } }
    }

    var featureExtrusionOpacity: Double = 0 {
        didSet {
            if oldValue != featureExtrusionOpacity {
                let newValue = featureExtrusionOpacity
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try map?.updateLayer(withId: Constants.LayerIDs.featureExtrusionLayer, type: FillExtrusionLayer.self) { layer in
                            layer.fillExtrusionOpacity = .constant(newValue)
                        }
                    } catch {}
                }
            }
        }
    }

    var wallExtrusionOpacity: Double = 0 {
        didSet {
            if oldValue != wallExtrusionOpacity {
                let newValue = wallExtrusionOpacity
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try map?.updateLayer(withId: Constants.LayerIDs.wallExtrusionLayer, type: FillExtrusionLayer.self) { layer in
                            layer.fillExtrusionOpacity = .constant(newValue)
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

    @MainActor
    private func removeOldModels(models: [any MPViewModel]) async {
        let modelsNoLongerInView = _lastModels.subtracting(models as! [AnyHashable])
        for model in modelsNoLongerInView {
            if let viewModel = model as? (any MPViewModel) {
                await removeInfoWindow(for: viewModel)
            }
        }
        _lastModels.removeAll(keepingCapacity: false)
    }

    func invalidateRenderCache() {
        imagesAdded.removeAll()
        self.modelCache.removeAll()
    }

    // LRU cache for storing computed GeoJSON -> Mapbox Feature results, as a heuristic to optimize the rendering pipeline's performance.
    private var modelCache = LRUCache<String, ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])>(countLimit: 10_000)
    func render(models: [any MPViewModel]) async throws {
        try Task.checkCancellation()
        let startTime = DispatchTime.now()
        await self.removeOldModels(models: models)
        try Task.checkCancellation()
        let generatedModels = try await withThrowingTaskGroup(of: ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature]).self) { group -> [([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])] in
            for model in models {
                _ = group.addTaskUnlessCancelled(priority: .userInitiated) { [weak self] in
                    guard let self else { return ([], [], [], [], [], []) }

                    await updateInfoWindow(for: model)

                    let cacheKey = model.featureCacheKey
                    if let cacheHit = lock.locked({ self.modelCache[cacheKey] }) {
                        return cacheHit
                    }

                    Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        try await self.updateImage(for: model)
                        try Task.checkCancellation()
                        try await self.update2DModel(for: model)
                    }

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

                    try Task.checkCancellation()

                    if let polygon = model.polygonFeature {
                        featuresGeometry.append(polygon)
                    }

                    try Task.checkCancellation()

                    if isFloorPlanEnabled, let floorPlan = model.floorPlanFeature {
                        featuresGeometry.append(floorPlan)
                    }

                    try Task.checkCancellation()

                    if is2dModelsEnabled, let model2D = model.model2DFeature,
                        let model2DGeometry = model.model2DGeometryFeature
                    {
                        features.append(model2D)
                        featuresGeometry.append(model2DGeometry)
                    }

                    try Task.checkCancellation()

                    if let model3D = model.model3DFeature {
                        features3DModels.append(model3D)
                    }

                    try Task.checkCancellation()

                    if isWallExtrusionsEnabled, let wallExtrusionLayer = model.wallExtrusionFeature {
                        featuresWalls.append(wallExtrusionLayer)
                    }

                    try Task.checkCancellation()

                    if isFeatureExtrusionsEnabled, let featureExtrusionLayer = model.featureExtrusionFeature {
                        featuresExtrusions.append(featureExtrusionLayer)
                    }

                    try Task.checkCancellation()

                    let result = (features, featuresGeometry, featuresNonCollision, featuresExtrusions, featuresWalls, features3DModels)

                    lock.locked { self.modelCache[cacheKey] = result }

                    return result
                }
            }

            try Task.checkCancellation()

            let res = try await group.reduce(into: [([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])]()) { result, feature in result.append(feature) }

            return res
        }

        await MainActor.run {
            _lastModels = Set(models.map { AnyHashable($0) })
        }

        var features = [Feature]()
        var featuresGeometry = [Feature]()
        var featuresNonCollision = [Feature]()
        var featuresExtrusions = [Feature]()
        var featuresWalls = [Feature]()
        var features3DModels = [Feature]()

        for x in generatedModels {
            features.append(contentsOf: x.0)
            featuresGeometry.append(contentsOf: x.1)
            featuresNonCollision.append(contentsOf: x.2)
            featuresExtrusions.append(contentsOf: x.3)
            featuresWalls.append(contentsOf: x.4)
            features3DModels.append(contentsOf: x.5)
        }

        let elapsedTimeInNanoSec = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let elapsedTimeInMilliSec = Double(elapsedTimeInNanoSec) / 1_000_000
        MPLog.mapbox.measure("ViewModels to Features", timeMs: elapsedTimeInMilliSec)

        // Allow cancellation before committing the atomic source update.
        // Partial updates can cause 3D walls/models to disappear.
        try Task.checkCancellation()

        await updateGeoJSONSource(
            features: features,
            geometryFeatures: featuresGeometry,
            nonCollisionFeatures: featuresNonCollision,
            featuresExtrusions: featuresExtrusions,
            featuresWalls: featuresWalls,
            features3DModels: features3DModels
        )
    }

    @MainActor
    private func removeInfoWindow(for model: any MPViewModel) async {
        if let infoWindow = infoWindows[model.id] {
            infoWindow.remove()
            infoWindows.removeValue(forKey: model.id)
        }
    }

    private func updateInfoWindow(for model: any MPViewModel) async {
        if model.showInfoWindow {
            if let point = model.marker?.geometry.coordinates as? MPPoint, let location = MPMapsIndoors.shared.locationWith(locationId: model.id) {
                await createOrUpdateInfoWindow(for: model, at: point, location: location)
            }
        } else if infoWindows[model.id] != nil {
            await removeInfoWindow(for: model)
        }
    }

    @MainActor
    private func createOrUpdateInfoWindow(for model: any MPViewModel, at point: MPPoint, location: MPLocation) async {
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

    /// Maps Mapbox style image IDs to the ObjectIdentifier of the UIImage that was last added,
    /// enabling O(1) change detection without expensive PNG encoding or MD5 hashing.
    private var imagesAdded = [String: ObjectIdentifier]()

    @MainActor
    private func updateImage(for model: any MPViewModel) async throws {
        guard let id = model.marker?.id else { return }

        if let icon = model.data[.icon] as? UIImage, model.marker?.properties[.hasImage] as? Bool == true {
            let imageIdentity = ObjectIdentifier(icon)
            guard imagesAdded[id] != imageIdentity else { return }
            try map?.addImage(icon, id: id)
            imagesAdded[id] = imageIdentity
        } else {
            try? map?.removeImage(withId: id)
            imagesAdded.removeValue(forKey: id)
        }

        if let graphicImage = model.data[.graphicLabelImage] as? UIImage,
            let id = model.marker?.properties[.labelGraphicId] as? String,
            let x = model.marker?.properties[.labelGraphicStretchX] as? [[Int]],
            let y = model.marker?.properties[.labelGraphicStretchY] as? [[Int]],
            let content = model.marker?.properties[.labelGraphicContent] as? [Int], content.count == 4
        {
            try map?.addImage(
                graphicImage,
                id: id,
                stretchX: x.compactMap { ImageStretches(first: Float($0[0]), second: Float($0[1])) },
                stretchY: y.compactMap { ImageStretches(first: Float($0[0]), second: Float($0[1])) },
                content: ImageContent(left: Float(content[0]), top: Float(content[1]), right: Float(content[2]), bottom: Float(content[3])))
        }
    }

    @MainActor
    private func update2DModel(for model: any MPViewModel) async throws {
        if let model2D = model.data[.model2D] as? UIImage, let id = model.model2D?.id, is2dModelsEnabled {
            let imageIdentity = ObjectIdentifier(model2D)
            guard imagesAdded[id] != imageIdentity else { return }
            try map?.addImage(model2D, id: id)
            imagesAdded[id] = imageIdentity
        }
    }

    var enabled = true {
        didSet {
            print("enabled: \(String(enabled))")
        }
    }

    @MainActor
    private func updateGeoJSONSource(features: [Feature], geometryFeatures: [Feature], nonCollisionFeatures: [Feature], featuresExtrusions: [Feature], featuresWalls: [Feature], features3DModels: [Feature]) async {
        // All six GeoJSON sources must be updated atomically — no cancellation
        // checks between them. A partial update (e.g. geometry updated but walls
        // left stale) causes features like 3D walls to disappear during rapid
        // camera movements when the RenderTaskQueue cancels in-flight tasks.
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonGeometrySource, geoJSON: .featureCollection(FeatureCollection(features: geometryFeatures)).geoJSONObject)
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonNoCollisionSource, geoJSON: .featureCollection(FeatureCollection(features: nonCollisionFeatures)).geoJSONObject)
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSourceExtrusions, geoJSON: .featureCollection(FeatureCollection(features: featuresExtrusions)).geoJSONObject)
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSourceWalls, geoJSON: .featureCollection(FeatureCollection(features: featuresWalls)).geoJSONObject)
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSource3dModels, geoJSON: .featureCollection(FeatureCollection(features: features3DModels)).geoJSONObject)
        map?.updateGeoJSONSource(withId: Constants.SourceIDs.geoJsonSource, geoJSON: .featureCollection(FeatureCollection(features: features)).geoJSONObject)
    }
}

// MARK: Extensions

/// We are extending the view model protocol with implementations for producing Mapbox 'Feature' objects.
extension MPViewModel {
    fileprivate var markerFeature: Feature? {
        guard let marker else { return nil }

        var feature = Feature(geometry: marker.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let hasImage = marker.properties[.hasImage] as? Bool { feature.properties?[Key.hasImage.rawValue] = JSONValue(hasImage) }
        if let markerId = marker.properties[.markerId] as? String { feature.properties?[Key.markerId.rawValue] = JSONValue(markerId) }
        if let markerIconPlacement = marker.properties[.markerIconPlacement] as? String { feature.properties?[Key.markerIconPlacement.rawValue] = JSONValue(markerIconPlacement) }
        if let labelType = (marker.properties[.labelType] as? MPLabelType)?.rawValue { feature.properties?[Key.labelType.rawValue] = JSONValue(labelType) }
        if let markerLabel = marker.properties[.markerLabel] as? String { feature.properties?[Key.markerLabel.rawValue] = JSONValue(markerLabel) }
        if let labelAnchor = marker.properties[.labelAnchor] as? String { feature.properties?[Key.labelAnchor.rawValue] = JSONValue(labelAnchor) }
        if let labelOffset = marker.properties[.labelOffset] as? [Double] {
            feature.properties?[Key.labelOffset.rawValue] = JSONValue(JSONArray(labelOffset.map { JSONValue($0) }))
        }
        if let markerGeometryArea = marker.properties[.markerGeometryArea] as? Double { feature.properties?[Key.markerGeometryArea.rawValue] = JSONValue(markerGeometryArea) }
        if let labelMaxWidth = marker.properties[.labelMaxWidth] as? UInt { feature.properties?[Key.labelMaxWidth.rawValue] = JSONValue(Int(labelMaxWidth)) }
        if let labelSize = marker.properties[.labelSize] as? Int { feature.properties?[Key.labelSize.rawValue] = JSONValue(labelSize) }
        if let labelColor = marker.properties[.labelColor] as? String { feature.properties?[Key.labelColor.rawValue] = JSONValue(labelColor) }
        if let labelOpacity = marker.properties[.labelOpacity] as? Double { feature.properties?[Key.labelOpacity.rawValue] = JSONValue(labelOpacity) }
        if let labelHaloColor = marker.properties[.labelHaloColor] as? String { feature.properties?[Key.labelHaloColor.rawValue] = JSONValue(labelHaloColor) }
        if let labelHaloWidth = marker.properties[.labelHaloWidth] as? Int { feature.properties?[Key.labelHaloWidth.rawValue] = JSONValue(labelHaloWidth) }
        if let labelHaloBlur = marker.properties[.labelHaloBlur] as? Int { feature.properties?[Key.labelHaloBlur.rawValue] = JSONValue(labelHaloBlur) }
        if let labelBearing = marker.properties[.labelBearing] as? Double { feature.properties?[Key.labelBearing.rawValue] = JSONValue(labelBearing) }
        if let labelGraphicId = marker.properties[.labelGraphicId] as? String { feature.properties?[Key.labelGraphicId.rawValue] = JSONValue(labelGraphicId) }
        if let labelGraphicStretchX = marker.properties[.labelGraphicStretchX] as? [[Int]] {
            feature.properties?[Key.labelGraphicStretchX.rawValue] = JSONValue(JSONArray(labelGraphicStretchX.map { JSONValue(JSONArray($0.map { JSONValue(Int($0)) })) }))
        }
        if let labelGraphicStretchY = marker.properties[.labelGraphicStretchY] as? [[Int]] {
            feature.properties?[Key.labelGraphicStretchY.rawValue] = JSONValue(JSONArray(labelGraphicStretchY.map { JSONValue(JSONArray($0.map { JSONValue($0) })) }))
        }
        if let labelGraphicContent = marker.properties[.labelGraphicContent] as? [Int] {
            feature.properties?[Key.labelGraphicContent.rawValue] = JSONValue(JSONArray(labelGraphicContent.map { JSONValue($0) }))
        }
        if let markerType = (marker.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(markerType) }

        return feature
    }

    fileprivate var polygonFeature: Feature? {
        guard let polygon else { return nil }

        var feature = Feature(geometry: polygon.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let polygonFillcolor = polygon.properties[.polygonFillcolor] as? String { feature.properties?[Key.polygonFillcolor.rawValue] = JSONValue(polygonFillcolor) }
        if let polygonFillOpacity = polygon.properties[.polygonFillOpacity] as? Double { feature.properties?[Key.polygonFillOpacity.rawValue] = JSONValue(polygonFillOpacity) }
        if let polygonStrokeColor = polygon.properties[.polygonStrokeColor] as? String { feature.properties?[Key.polygonStrokeColor.rawValue] = JSONValue(polygonStrokeColor) }
        if let polygonStrokeOpacity = polygon.properties[.polygonStrokeOpacity] as? Double { feature.properties?[Key.polygonStrokeOpacity.rawValue] = JSONValue(polygonStrokeOpacity) }
        if let polygonStrokeWidth = polygon.properties[.polygonStrokeWidth] as? Double { feature.properties?[Key.polygonStrokeWidth.rawValue] = JSONValue(polygonStrokeWidth) }
        if let polygonType = (polygon.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(polygonType) }

        return feature
    }

    fileprivate var floorPlanFeature: Feature? {
        guard let floorPlan = floorPlanExtrusion else { return nil }

        var feature = Feature(geometry: floorPlan.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let floorPlanFillColor = floorPlan.properties[.floorPlanFillColor] as? String { feature.properties?[Key.floorPlanFillColor.rawValue] = JSONValue(floorPlanFillColor) }
        if let floorPlanFillOpacity = floorPlan.properties[.floorPlanFillOpacity] as? Double { feature.properties?[Key.floorPlanFillOpacity.rawValue] = JSONValue(floorPlanFillOpacity) }
        if let floorPlanStrokeColor = floorPlan.properties[.floorPlanStrokeColor] as? String { feature.properties?[Key.floorPlanStrokeColor.rawValue] = JSONValue(floorPlanStrokeColor) }
        if let floorPlanStrokeOpacity = floorPlan.properties[.floorPlanStrokeOpacity] as? Double { feature.properties?[Key.floorPlanStrokeOpacity.rawValue] = JSONValue(floorPlanStrokeOpacity) }
        if let floorPlanStrokeWidth = floorPlan.properties[.floorPlanStrokeWidth] as? Double { feature.properties?[Key.floorPlanStrokeWidth.rawValue] = JSONValue(floorPlanStrokeWidth) }
        if let floorPlanType = (floorPlan.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(floorPlanType) }

        return feature
    }

    fileprivate var model2DFeature: Feature? {
        guard let model2D else { return nil }

        var feature = Feature(geometry: nil)

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let model2dId = model2D.properties[.model2dId] as? String { feature.properties?[Key.model2dId.rawValue] = JSONValue(model2dId) }
        if let model2dBearing = model2D.properties[.model2dBearing] as? Double { feature.properties?[Key.model2dBearing.rawValue] = JSONValue(model2dBearing) }
        if let model2DScale = model2D.properties[.model2DScale] as? Double { feature.properties?[Key.model2DScale.rawValue] = JSONValue(model2DScale) }
        if let model2DIsElevated = model2D.properties[.model2DIsElevated] as? Bool { feature.properties?[Key.model2DIsElevated.rawValue] = JSONValue(model2DIsElevated) }
        if let model2DType = (model2D.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(model2DType) }

        return feature
    }

    fileprivate var model2DGeometryFeature: Feature? {
        guard let center = ((model2D?.geometry as? MPViewModelFeatureGeometry)?.coordinates as? MPPoint)?.coordinate,
            let bearing = model2D?.properties[.model2dBearing] as? Double,
            let width = model2D?.properties[.model2DWidth] as? Double,
            let height = model2D?.properties[.model2DHeight] as? Double
        else { return nil }

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
        feature.properties?[Key.type.rawValue] = JSONValue(MPRenderedFeatureType.model2d.rawValue)

        return feature
    }

    fileprivate var model3DFeature: Feature? {
        guard let model3D else { return nil }

        var feature = Feature(geometry: model3D.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let model3dId = model3D.properties[.model3dId] as? String { feature.properties?[Key.model3dId.rawValue] = JSONValue(model3dId) }
        if let scale = model3D.properties[.model3DScale] as? [Double] {
            feature.properties?[Key.model3DScale.rawValue] = JSONValue(JSONArray(scale.map { JSONValue($0) }))
        }
        if let rotation = model3D.properties[.model3DRotation] as? [Double] {
            feature.properties?[Key.model3DRotation.rawValue] = JSONValue(JSONArray(rotation.map { JSONValue($0) }))
        }
        if let model3DType = (model3D.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(model3DType) }

        return feature
    }

    fileprivate var wallExtrusionFeature: Feature? {
        guard let wallExtrusion else { return nil }

        var feature = Feature(geometry: wallExtrusion.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let wallExtrusionColor = wallExtrusion.properties[.wallExtrusionColor] as? String { feature.properties?[Key.wallExtrusionColor.rawValue] = JSONValue(wallExtrusionColor) }
        if let wallExtrusionHeight = wallExtrusion.properties[.wallExtrusionHeight] as? Double { feature.properties?[Key.wallExtrusionHeight.rawValue] = JSONValue(wallExtrusionHeight) }
        if let wallExtrusionType = (wallExtrusion.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(wallExtrusionType) }

        return feature
    }

    fileprivate var featureExtrusionFeature: Feature? {
        guard let featureExtrusion else { return nil }

        var feature = Feature(geometry: featureExtrusion.geometry.featureGeometry())

        feature.identifier = .string(id)
        feature.properties = JSONObject()
        if let featureExtrusionColor = featureExtrusion.properties[.featureExtrusionColor] as? String { feature.properties?[Key.featureExtrusionColor.rawValue] = JSONValue(featureExtrusionColor) }
        if let featureExtrusionHeight = featureExtrusion.properties[.featureExtrusionHeight] as? Double { feature.properties?[Key.featureExtrusionHeight.rawValue] = JSONValue(featureExtrusionHeight) }
        if let featureExtrusionType = (featureExtrusion.properties[.type] as? MPRenderedFeatureType)?.rawValue { feature.properties?[Key.type.rawValue] = JSONValue(featureExtrusionType) }

        return feature
    }
}

extension CLLocationCoordinate2D {
    fileprivate func computeOffset(distanceMeters: Double, heading: Double) -> CLLocationCoordinate2D {
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

extension UIImage {
    fileprivate func scaled(size: CGSize) -> UIImage? {
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

extension LRUCache<String, ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])> {
    fileprivate subscript(key: String) -> ([Feature], [Feature], [Feature], [Feature], [Feature], [Feature])? {
        get {
            value(forKey: key)
        }
        set {
            if let array = newValue {
                let stride = MemoryLayout<Feature>.stride
                let usedBytes = array.0.count * stride + array.1.count * stride + array.2.count * stride + array.3.count * stride + array.4.count * stride + array.5.count * stride

                setValue(array, forKey: key, cost: usedBytes)
            } else {
                removeValue(forKey: key)
            }
        }
    }
}

extension MPPolygonGeometry {
    func toPolygon() -> Polygon {
        let coordinates: [[CLLocationCoordinate2D]] = self.coordinates.map {
            $0.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }
        return Polygon(coordinates)
    }
}

extension [[MPPoint]] {
    func toPolygon() -> Polygon {
        let coordinates: [[CLLocationCoordinate2D]] = self.map {
            $0.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }
        return Polygon(coordinates)
    }
}

extension MPMultiPolygonGeometry {
    func toMultiPolygon() -> MultiPolygon {
        let coordinates: [[[CLLocationCoordinate2D]]] = self.coordinates.map {
            $0.coordinates.map {
                $0.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
        }
        return MultiPolygon(coordinates)
    }
}

extension [MPPolygonGeometry] {
    func toMultiPolygon() -> MultiPolygon {
        let polygons: [Polygon] = self.map {
            $0.toPolygon()
        }
        return MultiPolygon(polygons)
    }
}

extension [[[MPPoint]]] {
    func toMultiPolygon() -> MultiPolygon {
        let coordinates: [[[CLLocationCoordinate2D]]] = self.map {
            $0.map {
                $0.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
        }
        return MultiPolygon(coordinates)
    }
}

extension MPViewModelFeatureGeometry {
    func featureGeometry() -> GeometryConvertible? {
        switch coordinates {
        case is MPPoint:
            Point((coordinates as! MPPoint).coordinate)
        case is [[MPPoint]]:
            (coordinates as! [[MPPoint]]).toPolygon()
        case is MPPolygonGeometry:
            (coordinates as! MPPolygonGeometry).toPolygon()
        case is [[[MPPoint]]]:
            (coordinates as! [[[MPPoint]]]).toMultiPolygon()
        case is [MPPolygonGeometry]:
            (coordinates as! [MPPolygonGeometry]).toMultiPolygon()
        case is MPMultiPolygonGeometry:
            (coordinates as! MPMultiPolygonGeometry).toMultiPolygon()
        default:
            nil
        }
    }
}
