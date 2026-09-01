import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore

class MBTileProvider {
    /// Reports whether the device currently has a network path.
    ///
    /// Injected so a test can drive the online-to-offline transition — the one case the source
    /// cannot be patched across. `NetworkPathMonitor.shared` is a process-wide singleton that a
    /// unit-test host reports as disconnected and that resolves asynchronously, so which branch
    /// the provider took could not otherwise be pinned from a test.
    typealias ConnectivityProbe = () -> Bool

    private weak var mapView: MapView?
    private weak var mapProvider: MapBoxProvider?
    public var _tileProvider: MPTileProvider
    private var rasterSource: RasterSource
    private let isConnected: ConnectivityProbe
    private var connectivityObserver: NSObjectProtocol?

    /// `mapProvider` is only read for its `transitionLevel` and is already held weakly, so it is
    /// optional: that lets a test drive the source lifecycle against a bare `MapView` without
    /// standing up a whole map provider.
    init(
        mapView: MapView?,
        tileProvider: MPTileProvider,
        mapProvider: MapBoxProvider?,
        isConnected: @escaping ConnectivityProbe = { NetworkPathMonitor.shared.isConnected }
    ) {
        self.mapView = mapView
        self.mapProvider = mapProvider
        _tileProvider = tileProvider
        self.isConnected = isConnected
        rasterSource = RasterSource(id: Constants.SourceIDs.tileSource)

        /// The source is deliberately NOT registered here. It carries no `tiles` until
        /// `updateSource()` resolves the template, and Mapbox rejects a raster source without
        /// tiles ("source must have tiles") — so an add here could only ever fail. `update()`
        /// below registers it. Mapbox logs "Source 'TILE_SOURCE' missing for layer 'TILE_LAYER'"
        /// for the one frame in between, which is cosmetic.
        self.mapView?.mapboxMap.addMapsIndoorsLayers()
        update()
        observeConnectivityChanges()
    }

    deinit {
        if let connectivityObserver {
            NotificationCenter.default.removeObserver(connectivityObserver)
        }
    }

    /// Re-resolves the tile template when connectivity changes.
    ///
    /// Nothing else does. `update()` is otherwise reached only through
    /// `MPMapControl.refreshTiles()`, which runs on a floor, venue or map-style change, so a
    /// device that regained its network kept whatever template it had resolved while offline
    /// until the user happened to change floor.
    ///
    /// `NetworkPathMonitor` posts on every path update rather than only on a change of status, so
    /// this fires often, sometimes several times in quick succession. A repeat post is cheap
    /// rather than free: `updateSource()` returns as soon as it sees the template already in
    /// effect matches the desired one, so no source work is repeated, but `updateLayer()` still
    /// re-applies the layer's position, fade and opacity. Those writes are idempotent and produce
    /// no visible change, which is why the post is not filtered — `MapboxWorldTransitionHandler`
    /// observes the same notification on the same terms.
    private func observeConnectivityChanges() {
        connectivityObserver = NotificationCenter.default.addObserver(
            forName: NetworkPathMonitor.networkStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.update()
        }
    }

    func update() {
        DispatchQueue.main.async {
            /// Independent steps with independent error handling: the layer still needs its
            /// source, fade and opacity applied even when re-configuring the source failed.
            /// Sharing one `do` block meant a single throw in the source step skipped the layer
            /// step entirely.
            do {
                try self.updateSource()
            } catch {
                MPLog.mapbox.error("Error updating tile source: \(error.localizedDescription)")
            }
            do {
                try self.updateLayer()
            } catch {
                MPLog.mapbox.error("Error updating tile layer: \(error.localizedDescription)")
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
                try addTileLayer(on: map)
            } catch {
                MPLog.mapbox.error("Failed to recreate tile layer: \(error.localizedDescription)")
            }
        }
    }

    /// Adds the tile layer at the bottom of the MapsIndoors stack, mirroring the order in
    /// `addMapsIndoorsLayers()`. Position matters: an unpositioned add lands the tiles at the top
    /// of their slot, above the polygons, floor plans and labels meant to draw over them.
    private func addTileLayer(on map: MapboxMap) throws {
        let layerId = Constants.LayerIDs.tileLayer
        var rasterLayer = RasterLayer(id: layerId, source: Constants.SourceIDs.tileSource)
        rasterLayer.slot = Constants.slotForLayerId[layerId]
        if map.layerExists(withId: Constants.LayerIDs.polygonFillLayer) {
            try map.addPersistentLayer(rasterLayer, layerPosition: .below(Constants.LayerIDs.polygonFillLayer))
        } else {
            try map.addPersistentLayer(rasterLayer)
        }
    }

    /// The tile template and raster settings for the current connectivity.
    ///
    /// The offline template is only worth choosing when a tile package has actually been
    /// downloaded. Without one it addresses a folder that does not exist, so every tile misses and
    /// the floor plan disappears — whereas staying on the online template lets Mapbox keep drawing
    /// the tiles it already holds in its own cache, which is what a device losing its network
    /// should show.
    private func desiredConfiguration() -> (url: String, tileSize: Double, volatile: Bool) {
        guard isConnected() == false, _tileProvider.hasOfflineTiles() else {
            return (_tileProvider.templateUrl(), _tileProvider.tileSize(), false)
        }
        return (_tileProvider.offlineTemplateUrl(), 256, true)
    }

    /// The offline template is a `file:` URL by construction — see `MPTileProvider`'s
    /// `offlineTilesTemplate` — so the scheme is what separates the two configurations, and the
    /// only thing readable about a template that some earlier provider registered.
    private func isOfflineTemplate(_ url: String?) -> Bool {
        url?.hasPrefix("file://") ?? false
    }

    /// The template the style currently holds, or `nil` when the source carries none.
    private func tilesInEffect(on map: MapboxMap) -> String? {
        (map.sourceProperty(for: Constants.SourceIDs.tileSource, property: "tiles").value as? [Any])?
            .first as? String
    }

    /// Removes and re-adds the source so that every property takes effect together, including the
    /// ones Mapbox will not accept on a source that is already registered.
    ///
    /// The layer has to come off first: Mapbox refuses to remove a source a layer still
    /// references, and refuses to leave a layer's `source` empty — that detach
    /// (`updateLayer.source = .none`) is exactly what Mapbox 11.25 started rejecting.
    ///
    /// Reserved for a change of connectivity mode. Doing this on every re-point cancels all
    /// in-flight tile requests, which during a rapid refresh cycle stops tiles ever finishing.
    private func reregisterSource(on map: MapboxMap) throws {
        let layerId = Constants.LayerIDs.tileLayer
        let hadLayer = map.layerExists(withId: layerId)
        if hadLayer {
            try map.removeLayer(withId: layerId)
        }

        /// Put the layer back whatever happens to the source in between. Leaving the style without
        /// a tile layer would take the floor plan away until the next full map setup, which is a
        /// worse outcome than the stale source this is replacing.
        defer {
            if hadLayer, map.layerExists(withId: layerId) == false {
                do {
                    try addTileLayer(on: map)
                } catch {
                    MPLog.mapbox.error("Failed to restore the tile layer: \(error.localizedDescription)")
                }
            }
        }

        try map.removeSource(withId: Constants.SourceIDs.tileSource)
        try map.addSource(rasterSource)
    }

    private func updateSource() throws {
        let desired = desiredConfiguration()
        rasterSource.tiles = [desired.url]
        rasterSource.tileSize = desired.tileSize
        rasterSource.volatile = desired.volatile

        guard let map = mapView?.mapboxMap else { return }

        guard map.sourceExists(withId: Constants.SourceIDs.tileSource) else {
            try map.addSource(rasterSource)
            return
        }

        /// Compare against what the style actually holds, NOT this instance's own last write.
        /// Every floor change builds a fresh `MBTileProvider`, so the source in effect may have
        /// been registered by an earlier one against a different — or unusable — template, and
        /// only the style knows which. Keying off local state here means a stale source is never
        /// recognised as stale, and re-applying unconditionally would cancel in-flight tile
        /// requests on every refresh.
        let inEffect = tilesInEffect(on: map)
        guard inEffect != desired.url else { return }

        guard isOfflineTemplate(inEffect) == isOfflineTemplate(desired.url) else {
            /// The connectivity mode flipped, so `tileSize` and `volatile` differ too — 512 and
            /// persistent online, 256 and volatile offline — and Mapbox rejects a write to
            /// `tileSize` on a source that is already registered. Patching would leave the source
            /// half-updated: addressing the new template while still configured for the old one.
            /// Only re-registering applies all three together, which is why relaunching the app
            /// used to be the only way back off an offline template.
            try reregisterSource(on: map)
            return
        }

        /// Same mode, so only the URL moved — a floor change. `tiles` is the one property Mapbox
        /// accepts on a registered source, and patching it leaves the tile requests already in
        /// flight alive, which removing and re-adding the source would cancel.
        ///
        /// This previously detached the layer from its source (`updateLayer.source = .none`)
        /// before removing and re-adding the source, but Mapbox rejects an empty layer source —
        /// "'source' property cannot be empty" — so the sequence threw on its first statement and
        /// the source was never re-registered. The first template to reach the style therefore
        /// stuck for the rest of the session.
        try map.setSourceProperty(for: Constants.SourceIDs.tileSource, property: "tiles", value: [desired.url])
    }

    /// Keeps the tile layer at the bottom of the MapsIndoors stack. This used to run inside the
    /// source-detach closure, so it never actually executed once that closure started throwing.
    private func positionTileLayerBelowPolygons() {
        guard let map = mapView?.mapboxMap,
            map.layerExists(withId: Constants.LayerIDs.polygonFillLayer)
        else { return }

        do {
            try map.moveLayer(withId: Constants.LayerIDs.tileLayer, to: .below(Constants.LayerIDs.polygonFillLayer))
        } catch {
            MPLog.mapbox.error(error.localizedDescription)
        }
    }

    private func updateLayer() throws {
        ensureTileLayerIsRasterLayer()
        positionTileLayerBelowPolygons()

        try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.tileLayer, type: RasterLayer.self) { updateLayer in
            updateLayer.source = Constants.SourceIDs.tileSource
            updateLayer.rasterFadeDuration = .constant(0.5)

            if let transitionLevel = mapProvider?.transitionLevel {
                let stops: [Double: Exp] = [
                    Double(transitionLevel): Exp(.literal) { 0.0 },
                    Double(transitionLevel) + 1.0: Exp(.literal) { 1.0 },
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
