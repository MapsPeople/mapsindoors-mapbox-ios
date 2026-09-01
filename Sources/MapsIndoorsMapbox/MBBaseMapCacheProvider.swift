import CoreLocation
import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoors

/// Mapbox implementation of ``MapProviderBaseMapCache`` that uses ``TileStore`` to
/// pre-download base-map tiles for a set of geographic regions.
///
/// - Important: This uses Mapbox's **app-wide** default offline store — `TileStore.default`
///   and a bare `OfflineManager()` (see the `init` defaults), the same store any host-app
///   Mapbox offline usage shares. Two consequences follow, by design: MapsIndoors is treated
///   as the owner of the app's Mapbox offline store.
///   1. `cachedRegionSize` / `cachedRegionIds()` report **everything** in that store, not only
///      MapsIndoors' own regions/packs. (Per-dataset size is scoped separately via
///      `cachedRegionSize(forRegionIds:)`.)
///   2. `removeCachedRegion(id:)` reclaims persisted style packs once the store holds no tile
///      regions at all (`removeStylePacksIfNoRegionsRemain()`), which will also remove style
///      packs a host app cached itself. A consumer app doing its own Mapbox offline caching
///      must not rely on the default store surviving MapsIndoors cache teardown. If a consumer
///      needs isolation, that requires giving MapsIndoors a dedicated `TileStore` (tracked as a
///      follow-up), not the shared default.
final class MBBaseMapCacheProvider: MapProviderBaseMapCache, @unchecked Sendable {

    private let tileStore: TileStore
    private let offlineManager: OfflineManager

    init(tileStore: TileStore = .default, offlineManager: OfflineManager = OfflineManager()) {
        self.tileStore = tileStore
        self.offlineManager = offlineManager
    }

    // MARK: - MapProviderBaseMapCache

    func cacheRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws {
        // Persist the style pack for the style the map actually loads (the MapsIndoors
        // wrapper style, or a consumer's custom style) so its style JSON / sprites /
        // glyphs — and the resources of any style it imports — are available on a cold
        // offline launch. The base-map *tiles* are cached separately below, from the base
        // map's own style (see makeDescriptors).
        try await loadStylePack(for: mapStyleURI(for: styleSource))

        // Hold the Cancelable so a cancelled enclosing Task stops the in-flight
        // download instead of letting it run to completion (network + battery).
        let cancelable = LockedCancelable()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Build the descriptors and start the load on the owning actor (see
                // runOnOwningActor). The load is async; its completion is delivered on a
                // TileStore worker thread, which is fine.
                self.runOnOwningActor {
                    let descriptors = self.makeDescriptors(for: styleSource, minZoom: minZoom, maxZoom: maxZoom)
                    guard let loadOptions = TileRegionLoadOptions(
                        geometry: self.polygonGeometry(for: bounds),
                        descriptors: descriptors,
                        acceptExpired: false
                    ) else {
                        continuation.resume(throwing: MPError.unknownError)
                        return
                    }
                    let cancel = self.tileStore.loadTileRegion(forId: id, loadOptions: loadOptions) { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                    cancelable.set(cancel)
                }
            }
        } onCancel: {
            // Cancelling does not orphan the continuation: per MapboxCommon's contract
            // (`TileRegionErrorType.canceled` — "The operation was canceled" — is a documented
            // load-request failure delivered through the completion above), cancelling the
            // Cancelable makes loadTileRegion invoke the completion with `.failure(.canceled)`,
            // which resumes the continuation. So this throws rather than hanging.
            cancelable.cancel()
        }
    }

    func removeCachedRegion(id: String) async throws {
        // TileStore.removeRegion returns Void (no Cancelable), so there is nothing
        // to wire into a cancellation handler — removal is a quick metadata op.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.runOnOwningActor {
                self.tileStore.removeRegion(forId: id) { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        // Style packs are keyed by style URI and shared across all regions of that style,
        // so they must outlive individual region removals. Only clean them up once the
        // last tile region is gone — otherwise a still-cached region would lose its style
        // resources. This stops style-pack storage leaking on full teardown.
        await removeStylePacksIfNoRegionsRemain()
    }

    func cachedRegionIds() async -> [String] {
        await withCheckedContinuation { continuation in
            self.runOnOwningActor {
                self.tileStore.allTileRegions { result in
                    switch result {
                    case .success(let regions): continuation.resume(returning: regions.map(\.id))
                    case .failure: continuation.resume(returning: [])
                    }
                }
            }
        }
    }

    var cachedRegionSize: UInt64 {
        get async {
            // Sum both the tile regions and the style pack(s) persisted alongside them —
            // the style pack (style JSON, sprites, glyphs) is stored separately by
            // OfflineManager, so counting only tile regions understates the real footprint.
            async let regionBytes = tileRegionsResourceSize()
            async let stylePackBytes = stylePacksResourceSize()
            return await regionBytes + stylePackBytes
        }
    }

    /// Size of the given tile regions only — deliberately **excludes** style-pack bytes,
    /// unlike the aggregate ``cachedRegionSize``. Style packs are keyed per style URI and
    /// shared across every region/dataset of that style, so attributing their bytes to one
    /// dataset would double-count them across datasets. Per-dataset size therefore counts
    /// only tile regions; the shared style-pack footprint is reflected in the aggregate.
    func cachedRegionSize(forRegionIds ids: [String]) async -> UInt64 {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return 0 }
        return await withCheckedContinuation { continuation in
            self.runOnOwningActor {
                self.tileStore.allTileRegions { result in
                    switch result {
                    case .success(let regions):
                        let total = regions
                            .filter { wanted.contains($0.id) }
                            .reduce(UInt64(0)) { $0 + $1.completedResourceSize }
                        continuation.resume(returning: total)
                    case .failure:
                        continuation.resume(returning: 0)
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Run `work` on the main actor — the thread that owns this provider's `TileStore`
    /// and `OfflineManager`. Both are bindgen objects created on the main thread in
    /// `MapBoxProvider.init`, so every call into them must originate on that thread, or
    /// Mapbox logs "called from a thread that is not owning the object". Their completion
    /// callbacks are delivered on a TileStore worker thread, which is fine. Centralised
    /// here so the invariant lives in one place across all the wrapping methods.
    private func runOnOwningActor(_ work: @MainActor @escaping () -> Void) {
        Task { @MainActor in work() }
    }

    private func tileRegionsResourceSize() async -> UInt64 {
        await withCheckedContinuation { continuation in
            self.runOnOwningActor {
                self.tileStore.allTileRegions { result in
                    switch result {
                    case .success(let regions):
                        continuation.resume(returning: regions.reduce(UInt64(0)) { $0 + $1.completedResourceSize })
                    case .failure:
                        continuation.resume(returning: 0)
                    }
                }
            }
        }
    }

    private func stylePacksResourceSize() async -> UInt64 {
        await withCheckedContinuation { continuation in
            self.runOnOwningActor {
                self.offlineManager.allStylePacks { result in
                    switch result {
                    case .success(let packs):
                        continuation.resume(returning: packs.reduce(UInt64(0)) { $0 + $1.completedResourceSize })
                    case .failure:
                        continuation.resume(returning: 0)
                    }
                }
            }
        }
    }

    /// Remove every persisted style pack, but only when no tile regions remain (see
    /// `removeCachedRegion`). Style packs are shared per style URI, so this is the
    /// safe point to reclaim them without breaking a still-cached region.
    private func removeStylePacksIfNoRegionsRemain() async {
        guard await cachedRegionIds().isEmpty else { return }
        for styleURI in await allStylePackStyleURIs() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.runOnOwningActor {
                    self.offlineManager.removeStylePack(for: styleURI) { _ in continuation.resume() }
                }
            }
        }
    }

    private func allStylePackStyleURIs() async -> [StyleURI] {
        await withCheckedContinuation { continuation in
            self.runOnOwningActor {
                self.offlineManager.allStylePacks { result in
                    switch result {
                    case .success(let packs):
                        continuation.resume(returning: packs.compactMap { StyleURI(rawValue: $0.styleURI) })
                    case .failure:
                        continuation.resume(returning: [])
                    }
                }
            }
        }
    }

    /// The style the map actually loads for this source: the MapsIndoors wrapper style
    /// (which imports the Mapbox Standard base map as the "basemap" import), or a
    /// consumer-provided custom style.
    private func mapStyleURI(for source: MPMapboxStyleSource) -> StyleURI {
        switch source {
        case .mapsIndoorsDefault:
            return StyleURI(rawValue: Constants.Style.mapsIndoorsDefaultURI) ?? .standard
        case .custom(let url):
            return StyleURI(url: url) ?? .standard
        }
    }

    /// The tileset descriptors whose tile packs must be cached for the base map to render
    /// offline.
    ///
    /// The base map is always Mapbox **Standard**, cached from its own style URI.
    /// `createTilesetDescriptor` built from the MapsIndoors wrapper style does NOT capture
    /// the tilesets of the style it *imports* as "basemap", so caching the wrapper leaves
    /// the base map blank offline — the imported Standard style has to be cached directly.
    /// A custom style may additionally declare its own first-party sources, so it is cached
    /// alongside Standard.
    private func makeDescriptors(
        for source: MPMapboxStyleSource,
        minZoom: Double,
        maxZoom: Double
    ) -> [TilesetDescriptor] {
        // TilesetDescriptorOptions requires UInt8 zoom values — clamp to [0, 22].
        // Round the lower bound down and the upper bound up so the full requested
        // zoom range is covered rather than silently trimmed.
        let lo = UInt8(min(max(minZoom, 0), 22).rounded(.down))
        let hi = UInt8(min(max(maxZoom, 0), 22).rounded(.up))
        let zoomRange = lo...(max(lo, hi))
        let stylePackOptions = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: nil,
            acceptExpired: false
        )

        // The style the map itself loads is persisted separately via `loadStylePack`
        // (see `cacheRegion`). Attaching `stylePackOptions` to a descriptor for that same
        // style would fetch its style pack a second time (the `.custom` case, and the
        // `.standard` fallback when a custom URL fails to parse), so we only attach the
        // style-pack options to descriptors whose style isn't already covered by that call.
        let mapStyle = mapStyleURI(for: source).rawValue

        var styleURIs: [StyleURI] = [.standard]
        if case .custom(let url) = source, let custom = StyleURI(url: url) {
            styleURIs.append(custom)
        }
        return styleURIs.map { uri in
            let options: TilesetDescriptorOptions =
                uri.rawValue == mapStyle
                // Style pack already fetched via loadStylePack — cache tiles only.
                ? TilesetDescriptorOptions(styleURI: uri, zoomRange: zoomRange, tilesets: nil)
                : TilesetDescriptorOptions(styleURI: uri, zoomRange: zoomRange, tilesets: nil, stylePackOptions: stylePackOptions)
            return offlineManager.createTilesetDescriptor(for: options)
        }
    }

    /// Persist a style's style pack (style JSON, sprites, glyphs, and the resources of any
    /// styles it imports) so the style loads on a cold offline launch. Cancellable so a
    /// cancelled enclosing Task stops the in-flight download.
    private func loadStylePack(for styleURI: StyleURI) async throws {
        let cancelable = LockedCancelable()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.runOnOwningActor {
                    guard let options = StylePackLoadOptions(
                        glyphsRasterizationMode: .ideographsRasterizedLocally,
                        metadata: nil,
                        acceptExpired: false
                    ) else {
                        continuation.resume(throwing: MPError.unknownError)
                        return
                    }
                    let cancel = self.offlineManager.loadStylePack(for: styleURI, loadOptions: options) { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                    cancelable.set(cancel)
                }
            }
        } onCancel: {
            cancelable.cancel()
        }
    }

    // Build a closed polygon ring from the four corners of the bounding box.
    private func polygonGeometry(for bounds: MPGeoBounds) -> Geometry {
        let sw = bounds.southWest
        let ne = bounds.northEast
        let nw = CLLocationCoordinate2D(latitude: ne.latitude, longitude: sw.longitude)
        let se = CLLocationCoordinate2D(latitude: sw.latitude, longitude: ne.longitude)
        // Polygon init takes [[CLLocationCoordinate2D]]; ring must close.
        return .polygon(Polygon([[sw, se, ne, nw, sw]]))
    }
}

/// Thread-safe holder for a Mapbox `Cancelable`. The continuation body (which
/// assigns the `Cancelable`) and the task-cancellation handler (which cancels it)
/// can run on different threads, and cancellation may arrive before the operation
/// starts — in which case the eventual `set` cancels immediately.
private final class LockedCancelable: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelable: Cancelable?
    private var cancelled = false

    func set(_ c: Cancelable) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            c.cancel()
        } else {
            cancelable = c
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        cancelable?.cancel()
        cancelable = nil
    }
}
