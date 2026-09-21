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
///   3. Style packs accumulate across style changes. Each `cacheRegion` persists the style pack
///      for whatever style it resolves to, and `removeStylePacksIfNoRegionsRemain()` only
///      reclaims packs once the store holds **zero** tile regions, so a host that switches style
///      (or flips `useMapsIndoorsStyle`) and re-syncs leaves the previous style's pack on disk
///      until full teardown. It shows up in the numbers too: the aggregate `cachedRegionSize`
///      counts the dead pack, while the per-dataset `cachedRegionSize(forRegionIds:)` excludes
///      style packs entirely, so neither figure lets a host account for it. Bounded by how many
///      distinct styles a host actually uses, so left as a follow-up, but newly reachable since
///      SPEX-2553: before that only one style URI was ever requested. Raised in review on !2019.
final class MBBaseMapCacheProvider: MapProviderBaseMapCache, @unchecked Sendable {

    private let tileStore: TileStore
    private let offlineManager: OfflineManager
    /// Reads the style URI the map provider is *configured* to render, or `nil` when there is
    /// no map yet (caching can start before a `MapView` exists) or no injected reader.
    ///
    /// Configured, not live: during startup the map briefly shows Mapbox's default style while
    /// the MapsIndoors style is still loading, and caching in that window must not follow the
    /// transient value. `MapBoxProvider.styleURIForCaching` carries that reasoning; see
    /// ``resolvedStyleSource(for:)`` for why it is asked at cache time rather than stored.
    private let configuredStyleURI: (@MainActor @Sendable () -> String?)?

    init(
        tileStore: TileStore = .default,
        offlineManager: OfflineManager = OfflineManager(),
        configuredStyleURI: (@MainActor @Sendable () -> String?)? = nil
    ) {
        self.tileStore = tileStore
        self.offlineManager = offlineManager
        self.configuredStyleURI = configuredStyleURI
    }

    /// The style whose tiles and style pack should actually be cached.
    ///
    /// `MapsIndoorsCore` has no idea which style the map is rendering — it always asks for
    /// ``MPMapboxStyleSource/mapsIndoorsDefault``, meaning "whatever style the SDK is set up
    /// with". Resolving that here, against the style the provider is configured with, is what
    /// stops the cache diverging from what is on screen: an app that sets its own style (`useMapsIndoorsStyle = false`,
    /// or Flutter's `MapsIndoorsWidget.mapStyleUri`) otherwise cached the MapsIndoors style's
    /// resources and went blank offline — with no error, because caching genuinely succeeded.
    ///
    /// Deriving beats asking the caller to declare the style separately: there is no second
    /// value to keep in sync, so the mismatch cannot be reintroduced by forgetting to update
    /// one of them.
    ///
    /// Read at cache time rather than captured at registration because the host can change
    /// the style at any point after the provider is registered in `MapBoxProvider.init`.
    ///
    /// An explicit ``MPMapboxStyleSource/custom(styleURI:)`` from the caller is honoured as
    /// given — only the "use the SDK's style" request is resolved.
    @MainActor
    func resolvedStyleSource(for requested: MPMapboxStyleSource) -> MPMapboxStyleSource {
        guard case .mapsIndoorsDefault = requested else { return requested }
        guard
            let configured = configuredStyleURI?(),
            configured != Constants.Style.mapsIndoorsDefaultURI,
            let url = URL(string: configured)
        else {
            // No map yet, no reader, or the provider really is set to the MapsIndoors style.
            return requested
        }
        return .custom(styleURI: url)
    }

    // MARK: - MapProviderBaseMapCache

    let supportsBaseMapCaching = true

    func cacheRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws {
        // Resolve against the live map first, so everything below caches the style that is
        // actually being rendered rather than the one Core assumed (see resolvedStyleSource).
        let effectiveSource = await resolvedStyleSource(for: styleSource)

        // Persist the style pack for the style the map actually loads (the MapsIndoors
        // wrapper style, or a consumer's custom style) so its style JSON / sprites /
        // glyphs — and the resources of any style it imports — are available on a cold
        // offline launch. The base-map *tiles* are cached separately below, from the base
        // map's own style (see makeDescriptors).
        try await loadStylePack(for: mapStyleURI(for: effectiveSource))

        // Hold the Cancelable so a cancelled enclosing Task stops the in-flight
        // download instead of letting it run to completion (network + battery).
        let cancelable = LockedCancelable()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Build the descriptors and start the load on the owning actor (see
                // runOnOwningActor). The load is async; its completion is delivered on a
                // TileStore worker thread, which is fine.
                self.runOnOwningActor {
                    let descriptors = self.makeDescriptors(for: effectiveSource, minZoom: minZoom, maxZoom: maxZoom)
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

    func estimateRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws -> MPBaseMapSizeEstimate {
        // Deliberately no `loadStylePack` counterpart: the provider exposes no way to estimate
        // a style pack, and calling the real loader here would download it as a side effect of
        // asking a question. The style-pack bytes are therefore outside this figure — the same
        // exclusion `cachedRegionSize(forRegionIds:)` makes, so estimate and recorded size stay
        // comparable.
        let cancelable = LockedCancelable()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MPBaseMapSizeEstimate, Error>) in
                self.runOnOwningActor {
                    // The same descriptors and geometry the real download builds, so the
                    // estimate covers the actual request rather than an approximation.
                    let descriptors = self.makeDescriptors(for: styleSource, minZoom: minZoom, maxZoom: maxZoom)
                    guard let loadOptions = TileRegionLoadOptions(
                        geometry: self.polygonGeometry(for: bounds),
                        descriptors: descriptors,
                        acceptExpired: false
                    ) else {
                        continuation.resume(throwing: MPError.unknownError)
                        return
                    }
                    let cancel = self.tileStore.estimateTileRegion(
                        forId: id,
                        loadOptions: loadOptions,
                        // nil → the provider's default accuracy and timeouts.
                        estimateOptions: nil,
                        progress: { _ in }
                    ) { result in
                        switch result {
                        case .success(let estimate):
                            continuation.resume(returning: MPBaseMapSizeEstimate(
                                transferSize: estimate.transferSize,
                                storageSize: estimate.storageSize,
                                errorMargin: estimate.errorMargin))
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                    cancelable.set(cancel)
                }
            }
        } onCancel: {
            // As in cacheRegion: cancelling reports through the same TileRegionError.canceled
            // ("The operation was canceled"), delivered to the completion above, so the
            // continuation resumes by throwing rather than hanging.
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
    func mapStyleURI(for source: MPMapboxStyleSource) -> StyleURI {
        switch source {
        case .mapsIndoorsDefault:
            return StyleURI(rawValue: Constants.Style.mapsIndoorsDefaultURI) ?? .standard
        case .custom(let url):
            return StyleURI(url: url) ?? .standard
        }
    }

    /// The integer zoom range `TilesetDescriptorOptions` is built from.
    ///
    /// `TilesetDescriptorOptions` requires `UInt8` zoom values, so the `Double` bounds of the
    /// provider seam have to be clamped to Mapbox's `[0, 22]` and rounded. The lower bound
    /// rounds **down** and the upper bound **up** so a fractional request is covered in full
    /// rather than silently trimmed at either end. The `max(lo, hi)` guards an inverted
    /// request (`minZoom > maxZoom`), which would otherwise trap forming the range.
    ///
    /// Split out of ``makeDescriptors(for:minZoom:maxZoom:)`` so the arithmetic can be tested
    /// at its own granularity: a descriptor-level test can only observe the zoom range
    /// indirectly, through opaque `TilesetDescriptor` values, so the clamp and the rounding
    /// direction are far easier to pin down here.
    static func zoomRange(minZoom: Double, maxZoom: Double) -> ClosedRange<UInt8> {
        let lo = UInt8(min(max(minZoom, 0), 22).rounded(.down))
        let hi = UInt8(min(max(maxZoom, 0), 22).rounded(.up))
        return lo...(max(lo, hi))
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
    ///
    /// Note that Standard is appended unconditionally, which is right for any style that
    /// imports it (the MapsIndoors style does, and it was the only possibility before
    /// SPEX-2553) but not a certainty any more: a host style that does *not* import Standard
    /// still gets Standard's tilesets downloaded, which it will never draw. Wasted bytes
    /// rather than a wrong render, so it is recorded here rather than fixed.
    func makeDescriptors(
        for source: MPMapboxStyleSource,
        minZoom: Double,
        maxZoom: Double
    ) -> [TilesetDescriptor] {
        let zoomRange = Self.zoomRange(minZoom: minZoom, maxZoom: maxZoom)
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
        // Skip a custom style that *is* Standard. Since SPEX-2553 the source can be resolved
        // from the live map, and a host that never set a style of its own leaves the map on
        // Standard — which would otherwise append a second, identical descriptor here.
        if case .custom(let url) = source, let custom = StyleURI(url: url),
            custom.rawValue != StyleURI.standard.rawValue
        {
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
///
/// Internal rather than private so that ordering is unit-testable.
final class LockedCancelable: @unchecked Sendable {
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
