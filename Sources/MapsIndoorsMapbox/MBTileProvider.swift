import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore

class MBTileProvider {
    private weak var mapView: MapView?
    private weak var mapProvider: MapBoxProvider?
    public var _tileProvider: MPTileProvider
    private var rasterSource: RasterSource
    private var templateUrl: String!

    init(mapView: MapView?, tileProvider: MPTileProvider, mapProvider: MapBoxProvider) {
        self.mapView = mapView
        self.mapProvider = mapProvider
        _tileProvider = tileProvider
        rasterSource = RasterSource(id: Constants.SourceIDs.tileSource)
        self.mapView?.mapboxMap.addMapsIndoorsLayers()
        update()
    }

    func update() {
        DispatchQueue.main.async {
            do {
                try self.updateSource()
                try self.updateLayer()
            } catch {
                MPLog.mapbox.error("Error updating tile layer/source: \(error.localizedDescription)")
            }
        }
    }

    /// Ensures the tile layer exists as a `RasterLayer`. If the layer exists but has been replaced
    /// with a different type (e.g. `ModelLayer`), it is removed and re-added as a `RasterLayer`
    /// to prevent an `EXC_BAD_ACCESS` crash when Mapbox attempts to cast it to the wrong type.
    private func ensureTileLayerIsRasterLayer() {
        guard let map = mapView?.mapboxMap else { return }

        let layerId = Constants.LayerIDs.tileLayer
        guard map.layerExists(withId: layerId) else { return }

        // Attempt a no-op update as RasterLayer to verify the layer type matches
        do {
            try map.updateLayer(withId: layerId, type: RasterLayer.self) { _ in }
        } catch {
            // The layer exists but is not a RasterLayer — remove and re-add it
            MPLog.mapbox.error("Tile layer type mismatch detected, recreating as RasterLayer: \(error.localizedDescription)")
            do {
                try map.removeLayer(withId: layerId)
                let rasterLayer = RasterLayer(id: layerId, source: Constants.SourceIDs.tileSource)
                try map.addPersistentLayer(rasterLayer)
            } catch {
                MPLog.mapbox.error("Failed to recreate tile layer: \(error.localizedDescription)")
            }
        }
    }

    private func updateSource() throws {
        if NetworkPathMonitor.shared.isConnected {
            if templateUrl != _tileProvider.templateUrl() {
                templateUrl = _tileProvider.templateUrl()
                rasterSource.tiles = [templateUrl]
                rasterSource.tileSize = _tileProvider.tileSize()
                rasterSource.volatile = false
            }
        } else {
            if templateUrl != _tileProvider.offlineTemplateUrl() {
                templateUrl = _tileProvider.offlineTemplateUrl()
                rasterSource.tiles = [templateUrl]
                rasterSource.tileSize = 256
                rasterSource.volatile = true
            }
        }

        if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.tileSource) == false {
            try mapView?.mapboxMap.addSource(rasterSource)
            return
        }

        ensureTileLayerIsRasterLayer()

        try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.tileLayer, type: RasterLayer.self) { updateLayer in

            if mapView?.mapboxMap.layerExists(withId: Constants.LayerIDs.polygonFillLayer) ?? false {
                do {
                    try mapView?.mapboxMap.moveLayer(withId: Constants.LayerIDs.tileLayer, to: .below(Constants.LayerIDs.polygonFillLayer))
                } catch {
                    MPLog.mapbox.error(error.localizedDescription)
                }
            }
            updateLayer.source = .none
        }

        try mapView?.mapboxMap.removeSource(withId: Constants.SourceIDs.tileSource)
        try mapView?.mapboxMap.addSource(rasterSource)
    }

    private func updateLayer() throws {
        ensureTileLayerIsRasterLayer()

        try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.tileLayer, type: RasterLayer.self) { updateLayer in
            updateLayer.source = Constants.SourceIDs.tileSource
            updateLayer.rasterFadeDuration = .constant(0.5)
            updateLayer.slot = .middle

            if let transitionLevel = mapProvider?.transitionLevel {
                let stops: [Double: Exp] = [
                    Double(transitionLevel): Exp(.literal) { 0.0 },
                    Double(transitionLevel) + 1.0: Exp(.literal) { 1.0 }
                ]

                updateLayer.rasterOpacity = .expression(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.zoom)
                        stops
                    }
                )
            }
        }
    }
}
