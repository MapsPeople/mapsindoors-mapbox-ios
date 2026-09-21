import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoors
@_spi(Private) import MapsIndoorsCore
import os

/// Test seam over the single `MapboxMap.loadStyle` call `_loadMapbox()` makes.
/// Tests inject a fake to drive the completion — including firing it more than
/// once — so the resume-once guard and late-success recovery can be asserted
/// without a live Mapbox style / access token (SPEX-2169).
protocol MBStyleLoading: AnyObject {
    func loadMapsIndoorsStyle(_ styleURI: StyleURI, completion: @escaping (Error?) -> Void)
}

extension MapboxMap: MBStyleLoading {
    func loadMapsIndoorsStyle(_ styleURI: StyleURI, completion: @escaping (Error?) -> Void) {
        loadStyle(styleURI) { error in completion(error) }
    }
}

// SAFETY: (SPEX-1975) MapBoxProvider wraps main-thread-only Mapbox UI and is accessed on the main
// actor, so it is safe to share by that convention. (MPMapProvider is Sendable; the type-system
// proof is deferred with the wider provider-isolation work.)
//
// Two public setters are the exception, and are safe by construction rather than by that
// convention. `hideMapboxLogo` is written through `MPMapConfig.setHideMapboxLogo`, a non-isolated
// `@objc` API, and `padding` through a public, non-isolated property; a host can call either from
// any thread and isolation cannot be enforced statically against them, so an off-main write must
// not trap. Both are lock-backed rather than relying on this convention, because both are read on the
// main actor while being written from anywhere: `padding` by `adjustOrnaments()` and
// `MBCameraOperator`, `hideMapboxLogo` by `adjustOrnaments()` and `mapsPeopleLogoPosition`.
//
// They differ in how the ornament pass is scheduled. `padding` runs it synchronously when the
// write is already on the main actor, because the SDK's own writer pairs it with a logo-constraint
// move in the same turn; `hideMapboxLogo` always defers, like its deferring siblings, because
// nothing is paired with it. (That set is not the same four named below — it includes
// `enableNativeMapBuildings`, which has no off-main write path, and excludes `useMapsIndoorsStyle`,
// which has one but no `didSet`.)
//
// Those two are the only *synchronized* properties here, which is narrower than the exposure — do
// not read this block as saying the rest of the class is race-free. `transitionLevel`,
// `showMapboxMapMarkers`, `showMapboxRoadLabels` and `useMapsIndoorsStyle` are written through the
// same non-isolated `@objc extension MPMapConfig`, so they carry the identical off-main write
// exposure and are knowingly left unsynchronized — and nothing traps to reveal it: three defer via
// `Task { @MainActor }`, and `useMapsIndoorsStyle` is a bare store with no `didSet` at all. Their
// reads differ: the two `showMapbox*` flags are read by the
// `@MainActor` `MapboxWorldTransitionHandler`, `useMapsIndoorsStyle` within this class, and
// `transitionLevel` by `MBTileProvider`, which is not main-actor isolated at all — so that one can
// be off-main at both ends. None will tear in practice, being an `Int`, a `Bool` and two `Bool?`s,
// but that is a platform accident rather than a guarantee. A follow-up ticket carries them; they
// were left alone here rather than widening a two-setter crash fix into six locks.
//
// Every other property is written only by `MPMapControlInternal`, which is `@MainActor`, so those
// keep the convention in practice. Nothing enforces that either — `MPMapConfig.mapProvider` is
// public, so a host can reach this object off-main — so anything added here should say which of the
// three groups it belongs to rather than assuming the convention holds.
public class MapBoxProvider: MPMapProvider, @unchecked Sendable {
    public let model2DResolutionLimit = 500

    public var enableNativeMapBuildings: Bool = true {
        didSet {
            guard oldValue != enableNativeMapBuildings else { return }
            let value = enableNativeMapBuildings
            Task { @MainActor [weak self] in
                self?.mapboxTransitionHandler?.enableMapboxBuildings = value
            }
        }
    }

    public var useMapsIndoorsStyle: Bool = true

    /// Internal (not `private`) so tests can inject a spy via `@testable import` to
    /// assert that property didSet observers schedule a visibility re-apply.
    internal var mapboxTransitionHandler: MapboxWorldTransitionHandler?

    /// Test injection point for the style loader — when non-nil, the MapsIndoors
    /// style load routes here instead of the live `MapboxMap` (SPEX-2169).
    internal var styleLoaderOverride: MBStyleLoading?

    /// Whether the most recent MapsIndoors style load reported a failure. Used to
    /// recover when a later callback for the same attempt succeeds (e.g. after a
    /// dynamic access token arrives), rather than leaving the map on a style that
    /// never loaded (SPEX-2169).
    internal private(set) var styleLoadFailed = false

    /// The zoom level at which the map transitions between Mapbox-centric and
    /// MapsIndoors-centric rendering. Changing it re-applies the world/marker
    /// visibility against the current camera, so `setMapsIndoorsTransitionLevel`
    /// takes effect immediately rather than only once the level is next crossed
    /// by a camera movement (SPEX-2097).
    public var transitionLevel = 17 {
        didSet {
            guard oldValue != transitionLevel else { return }
            Task { @MainActor [weak self] in
                await self?.mapboxTransitionHandler?.reapplyVisibility()
            }
        }
    }

    /// Controls visibility of Mapbox base-map POI / place / transit labels.
    /// Only `true` shows them; `nil` (default) and `false` hide them.
    /// Aligned with the Android SDK's default-hidden behavior.
    public var showMapboxMapMarkers: Bool? {
        didSet {
            guard oldValue != showMapboxMapMarkers else { return }
            Task { @MainActor [weak self] in
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
    }

    /// Controls visibility of Mapbox base-map road labels.
    /// Only `true` shows them; `nil` (default) and `false` hide them.
    /// Aligned with the Android SDK's default-hidden behavior.
    public var showMapboxRoadLabels: Bool? {
        didSet {
            guard oldValue != showMapboxRoadLabels else { return }
            Task { @MainActor [weak self] in
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
    }

    private let _hideMapboxLogo = OSAllocatedUnfairLock(initialState: false)

    /// Controls visibility of the Mapbox logo (watermark).
    /// `false` (the default, matching the Android SDK's `hideMapboxLogo`
    /// builder option) shows the Mapbox logo in its default slot; `true`
    /// suppresses it and lets the MapsPeople branding logo take over the
    /// bottom-left watermark slot.
    ///
    /// Hops to the main actor asynchronously rather than asserting it, because the write can arrive
    /// from any thread: `MPMapConfig.setHideMapboxLogo` is a non-isolated `@objc` API, so a host app
    /// calling it off the main thread would otherwise hit a precondition failure inside
    /// `assumeIsolated`. Matches `showMapboxMapMarkers` above. The consequence is that
    /// `adjustOrnaments()` lands on a later main-actor turn, which is invisible here: nothing reads
    /// ornament state synchronously after the write, and `mapsPeopleLogoPosition` derives from the
    /// stored flag rather than from the views.
    public var hideMapboxLogo: Bool {
        get { _hideMapboxLogo.withLock { $0 } }
        set {
            // Synchronized for the same reason as `padding` below: the write arrives from an
            // `@objc` API that a host can call off the main thread, while `adjustOrnaments()` and
            // `mapsPeopleLogoPosition` read it on the main actor. A `Bool` will not tear on any
            // platform we ship, but an unsynchronized cross-thread access is still a data race by
            // the language's rules and by ThreadSanitizer's.
            //
            // The deferral stays unconditional, unlike `padding`: nothing is paired with this write
            // in the same turn, so there is no lag to remove, and this keeps the shape its four
            // sibling setters use.
            let changed = _hideMapboxLogo.withLock { current -> Bool in
                guard current != newValue else { return false }
                current = newValue
                return true
            }
            guard changed else { return }
            Task { @MainActor [weak self] in self?.adjustOrnaments() }
        }
    }

    public var wallExtrusionOpacity: Double = 0

    public var featureExtrusionOpacity: Double = 0

    public var routingService: MPExternalDirectionsService {
        MBDirectionsService(accessToken: accessToken)
    }

    public var distanceMatrixService: MPExternalDistanceMatrixService {
        MBDistanceMatrixService(accessToken: accessToken)
    }

    public var customInfoWindow: MPCustomInfoWindow?

    private var tileProvider: MBTileProvider?

    private var onStyleLoadedCancelable: AnyCancelable?

    @MainActor
    public func setTileProvider(tileProvider: MPTileProvider) async {
        self.tileProvider = MBTileProvider(mapView: mapView, tileProvider: tileProvider, mapProvider: self)
    }

    public func reloadTilesForFloorChange() {
        tileProvider?.update()
    }

    var renderer: MBRenderer?

    /// In-flight render task. A new `setViewModels` cancels and awaits this
    /// before starting its own render so two render task-groups never share
    /// `MPViewModel` references.
    @MainActor private var renderTask: Task<Void, Never>?

    private var _routeRenderer: MBRouteRenderer?

    public weak var view: UIView?

    /// Where the MapsPeople branding logo is anchored. When the Mapbox logo
    /// is hidden (`hideMapboxLogo == true`), the MapsPeople logo takes over
    /// the vacated bottom-left watermark slot and the attribution button
    /// shifts right of it. When the Mapbox logo is shown, the MapsPeople
    /// logo moves to the bottom-right so the two logos don't collide.
    public var mapsPeopleLogoPosition: MPMapsPeopleLogoPosition { hideMapboxLogo ? .bottomLeft : .bottomRight }

    private let _padding = OSAllocatedUnfairLock(initialState: UIEdgeInsets.zero)

    /// Synchronized rather than main-actor-only, unlike the rest of this class.
    ///
    /// The SDK's own writer (`MPMapControlInternal.mapPadding`) is `@MainActor`, but this is a
    /// `public var` on a public class with no isolation in its signature, so a host can write it
    /// from any thread. Asserting the main actor here trapped instead of hopping, which is the
    /// crash this fixes — but simply hopping the *side effect* would have left a 32-byte
    /// `UIEdgeInsets` being stored off-main while `adjustOrnaments()` and `MBCameraOperator` read
    /// it on the main actor, i.e. an unsynchronized read/write that can tear. The lock removes
    /// that rather than relying on the class-wide "main actor only" convention, which this
    /// property no longer satisfies.
    public var padding: UIEdgeInsets {
        get { _padding.withLock { $0 } }
        set {
            // Compare and store under the same lock: two racing writers cannot both observe a
            // change and schedule redundant work, and the guard matches the four sibling setters.
            let changed = _padding.withLock { current -> Bool in
                guard current != newValue else { return false }
                current = newValue
                return true
            }
            guard changed else { return }

            // Synchronously when the write is already on the main actor, deferred only when it is
            // not. `MPMapControlInternal.mapPadding` writes this and then moves the MapsPeople logo
            // constraint in the same turn, so deferring unconditionally made the Mapbox ornaments
            // lag that logo by one turn on every padding change — and a write inside a
            // `UIView.animate` block left the ornament move outside the animation. Hosts drive
            // padding during bottom-sheet drags, so that is a visible regression, not a theoretical
            // one. Off-main is the case that used to trap, and is the only one that defers.
            if Thread.isMainThread {
                MainActor.assumeIsolated { adjustOrnaments() }
            } else {
                Task { @MainActor [weak self] in self?.adjustOrnaments() }
            }
        }
    }

    public var mpAccessibilityElementsHidden: Bool = false

    public weak var delegate: MPMapProviderDelegate?

    public var positionPresenter: MPPositionPresenter

    public var collisionHandling: MPCollisionHandling = .allowOverLap

    /// Set this through ``MPMapControl/expandedTapAreaEnabled``, not here: the render path re-applies
    /// the map control's value, so a write straight to the provider is silently reverted on the next
    /// render. Public for the same reason as `collisionHandling` above — the protocol requires it.
    public var expandedTapAreaEnabled: Bool = true

    public var routeRenderer: MPRouteRenderer {
        _routeRenderer ?? MBRouteRenderer(mapView: mapView)
    }

    /// Invalidates the renderer's internal model cache.
    ///
    /// Submission is async (a `Task { @MainActor … }`), so the underlying clear
    /// runs on a later turn of MainActor's executor. Callers that follow this
    /// with `refresh()` (which itself wraps in a `Task { @MainActor … }`) get
    /// invalidate-before-refresh ordering for free via FIFO scheduling on the
    /// MainActor queue. Eventually consistent — do not assume the cache is
    /// empty the instant this returns.
    public func invalidateRenderCache() {
        Task { @MainActor [weak self] in
            self?.renderer?.invalidateRenderCache()
        }
    }

    @MainActor
    public func setViewModels(models: [any MPViewModel], forceClear _: Bool) async {
        if let r = renderer {
            configureMapsIndoorsModuleLicensing(map: mapView?.mapboxMap, renderer: r)
        }

        // Serialize renders so only one render flow is ever alive, even under
        // multiple concurrent callers. The predecessor is captured and the
        // replacement published with no `await` between the read of `renderTask`
        // and its reassignment, so a second caller arriving on the main actor
        // sees *this* task as its predecessor and chains behind it instead of
        // all parking on the same older task (which would let their renders run
        // concurrently once that shared predecessor completed). Awaiting the
        // predecessor — and the renderer property assignments that must not
        // mutate settings mid-flight — happen *inside* the new task, after the
        // prior render's task-group children have released their `MPViewModel`
        // captures.
        let previous = renderTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }

            // Ignore `forceClear` - not applicable to mapbox rendering
            self.renderer?.customInfoWindow = self.customInfoWindow
            self.renderer?.collisionHandling = self.collisionHandling
            self.renderer?.featureExtrusionOpacity = self.featureExtrusionOpacity
            self.renderer?.wallExtrusionOpacity = self.wallExtrusionOpacity

            do {
                try await self.renderer?.render(models: models)
            } catch {}
        }
        renderTask = task
        await task.value
    }

    public var cameraOperator: MPCameraOperator {
        guard let mapView else { return MBCameraOperator() }

        return MBCameraOperator(mapView: mapView, provider: self)
    }

    weak var mapView: MapView?

    private var accessToken: String

    private var performanceStatisticsCancelable: AnyCancelable?
    private weak var tapGestureRecognizer: UITapGestureRecognizer?

    public required init(mapView: MapView, accessToken: String) {
        self.mapView = mapView
        view = mapView
        self.accessToken = accessToken
        positionPresenter = MBPositionPresenter(map: self.mapView?.mapboxMap)

        mapboxTransitionHandler = MapboxWorldTransitionHandler(mapProvider: self)

        onStyleLoadedCancelable = self.mapView?.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            // Re-apply ornament hiding on every style load: Mapbox's
            // OrnamentsManager rebuilds its subviews when the style changes,
            // which resets the logoView's isHidden flag and re-attaches it
            // to the view hierarchy.
            //
            // Mapbox v11 delivers `onStyleLoaded` on the main thread in
            // practice but the callback's signature does not enforce it,
            // and `adjustOrnaments` touches UIKit (`logoView`,
            // `ornaments.options`). `assumeIsolated` traps loudly if a
            // future Mapbox version moves this off main instead of
            // silently racing on UIKit state.
            MainActor.assumeIsolated {
                self?.adjustOrnaments()
                // Remember what the map settled on, so base-map caching still knows the host's
                // style after the map view is gone (see `styleURIForCaching`).
                self?.rememberLoadedStyleURI()
            }
            // A style (re)load resets every style-import config back to its
            // defaults, so re-apply the MapsIndoors-vs-Mapbox world visibility
            // once the style is ready to accept it. This is the reliable
            // "style ready" signal and runs regardless of camera movement, so
            // the configured transition level is honoured even when the map
            // opens already zoomed past it and no camera event ever fires
            // (SPEX-2097).
            Task { [weak self] in
                await self?.mapboxTransitionHandler?.reapplyVisibility()
            }
            if self?.useMapsIndoorsStyle == false {
                Task { [weak self] in
                    await self?.verifySetup()
                }
            }
        }

        // The default Mapbox style begins loading during `MapView.init`,
        // so by the time our observer above subscribes, the initial
        // `onStyleLoaded` event may have already fired — `Signal.observe`
        // does not replay past events. Apply once synchronously so the
        // Mapbox logo is suppressed even when no further style load is
        // scheduled (SPEX-1786).
        MainActor.assumeIsolated {
            adjustOrnaments()
            // Same reason, for the same observer: the map may already be on a style by now, and
            // `lastLoadedStyleURI` would otherwise stay nil until the *next* load - which for a
            // host-owned style may never come.
            rememberLoadedStyleURI()
        }

        Task { [weak self] in
            await self?.verifySetup()
        }

        registerLocalFallbackFontWith(filenameString: "OpenSans-Bold.ttf", bundleIdentifierString: "Fonts")

        // Hand the cache provider a reader for the style rather than a fixed URI: the host can
        // set its own style at any point after this, and the cache has to follow it or the map
        // goes blank offline (SPEX-2553).
        MPMapsIndoors.baseMapCacheProvider = MBBaseMapCacheProvider(
            configuredStyleURI: { [weak self] in self?.styleURIForCaching })
    }

    private let styleUrl = Constants.Style.mapsIndoorsDefaultURI

    /// The style URI the map most recently finished loading, or `nil` before the first load.
    ///
    /// Exists because `mapView` is `weak`: once the host tears its map down there is nothing
    /// left to ask, and with `useMapsIndoorsStyle == false` the fallback would otherwise be the
    /// MapsIndoors style, the one style we know for certain is *not* what was rendered. That is
    /// reachable mid-sync rather than only at teardown, since base-map caching is long-running:
    /// a host that starts it and navigates away would get the first N regions cached against
    /// its own style and the rest against the MapsIndoors style. Raised in review on !2019.
    @MainActor
    private var lastLoadedStyleURI: String?

    /// Records the map's current style. Called from the `onStyleLoaded` observer, which is the
    /// point at which the map has actually settled on a style.
    @MainActor
    private func rememberLoadedStyleURI() {
        if let uri = mapView?.mapboxMap.styleURI?.rawValue {
            lastLoadedStyleURI = uri
        }
    }

    /// The style base-map caching should target — the style this provider is *configured* to
    /// render, which is not always the style the map is showing at the moment it is asked.
    ///
    /// Reporting the map's live `styleURI` instead would be wrong during startup: `MapView.init`
    /// begins loading Mapbox's own default style, and the MapsIndoors style only replaces it
    /// when `loadMapsIndoorsStyleResumingOnce()` completes inside `_loadMapbox()`. A host that
    /// starts caching in that window would read the transient default and cache its style pack
    /// instead of the MapsIndoors style that appears moments later — offline, the map would
    /// then come up without the style it actually renders. Raised by review on !2019.
    ///
    /// Answering from configuration removes that window rather than narrowing it: while
    /// ``useMapsIndoorsStyle`` is set, the SDK loads its own style over whatever is showing, so
    /// that is the style to cache no matter what the map is displaying right now. Only when the
    /// host has taken the style over does the live value become the authoritative answer — and
    /// then there is no transient phase, because the SDK never loads a style at all
    /// (see `_loadMapbox()`).
    @MainActor
    var styleURIForCaching: String? {
        Self.styleURIForCaching(
            useMapsIndoorsStyle: useMapsIndoorsStyle,
            mapsIndoorsStyleURI: styleUrl,
            currentStyleURI: mapView?.mapboxMap.styleURI?.rawValue,
            lastLoadedStyleURI: lastLoadedStyleURI)
    }

    /// The decision itself, split from the state it reads so it can be unit-tested across all
    /// four combinations. Exercising it through the property would mean deallocating a live
    /// `MapView` mid-test to reach the torn-down case, which destabilises the test host for no
    /// extra coverage - the same trade-off as ``MBBaseMapCacheProvider/zoomRange(minZoom:maxZoom:)``.
    ///
    /// `lastLoadedStyleURI` backstops a torn-down map, and is only consulted when the host owns
    /// the style: under `useMapsIndoorsStyle` the answer is a constant anyway. A map that never
    /// loaded a style has nothing remembered, so this returns `nil` and the caller's "no map
    /// yet" fallback to the MapsIndoors style still applies.
    @MainActor
    static func styleURIForCaching(
        useMapsIndoorsStyle: Bool,
        mapsIndoorsStyleURI: String,
        currentStyleURI: String?,
        lastLoadedStyleURI: String?
    ) -> String? {
        guard !useMapsIndoorsStyle else { return mapsIndoorsStyleURI }
        return currentStyleURI ?? lastLoadedStyleURI
    }

    private var cameraChangedCancellable: AnyCancelable? = nil
    private var cameraIdleCancellable: AnyCancelable? = nil
    private var _cameraDebounceTask: Task<Void, Never>?

    @MainActor
    private func verifySetup() async {
        await loadMapbox()
    }

    private var latestIdleTime = Date.now
    private var loadTask: Task<Void, Never>?

    /// Coalesces concurrent reload requests: a second caller awaits the
    /// in-flight load instead of silently no-opping and resuming on a
    /// half-configured map.
    @MainActor
    public func loadMapbox() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self._loadMapbox()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Loads the MapsIndoors Mapbox style and resumes the caller exactly once.
    ///
    /// Mapbox's `loadStyle` completion does not honour a once-only contract: its
    /// error and completed callbacks can both fire for the same load attempt.
    /// With a dynamic / backend-issued token the initial load 401s (`error`) and,
    /// once the token is set, gl-native retries the still-registered request and
    /// succeeds (`completed`) — invoking this closure a second time. Resuming a
    /// checked continuation twice is a fatal `SWIFT TASK CONTINUATION MISUSE`, so
    /// this guards to resume exactly once. No lock needed: `_loadMapbox()` is
    /// @MainActor and Mapbox delivers these callbacks on the main thread. The
    /// per-callback outcome is handed to `handleStyleLoadCallback` so a late
    /// success after an initial failure can recover the style (SPEX-2169).
    ///
    /// Extracted + routed through `styleLoaderOverride` so the guard and the
    /// recovery are unit-testable without a live Mapbox style / access token.
    @MainActor
    func loadMapsIndoorsStyleResumingOnce() async {
        // Scope the failure flag to this attempt. Mapbox retains the previous
        // attempt's completion closure indefinitely, so a late callback from an
        // earlier attempt could otherwise see a stale `styleLoadFailed` and
        // trigger spurious recovery against the wrong load. Resetting here also
        // keeps the flag consistent on the styleURI-nil / nil-loader early exits
        // (no load attempted) (SPEX-2169).
        styleLoadFailed = false
        guard let styleURI = StyleURI(url: URL(string: styleUrl)!) else { return }
        let loader = styleLoaderOverride ?? mapView?.mapboxMap
        await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            func resumeOnce() {
                guard didResume == false else { return }
                didResume = true
                continuation.resume()
            }
            guard let loader else {
                resumeOnce()
                return
            }
            loader.loadMapsIndoorsStyle(styleURI) { [weak self] error in
                let isFirstCallback = (didResume == false)
                resumeOnce()
                self?.handleStyleLoadCallback(error: error, isFirstCallback: isFirstCallback)
            }
        }
    }

    /// Reacts to a callback from the MapsIndoors style load. The first callback
    /// records the outcome (and surfaces a failure instead of silently proceeding
    /// as if the style loaded). A later callback for the same attempt that
    /// succeeds after the first failed means the style has now actually loaded
    /// (e.g. a dynamic token arrived and gl-native's retry succeeded) — recover by
    /// re-applying the style-import config against the now-loaded style, rather
    /// than leaving the map on the unloaded/default style (SPEX-2169).
    @MainActor
    func handleStyleLoadCallback(error: Error?, isFirstCallback: Bool) {
        if isFirstCallback {
            styleLoadFailed = (error != nil)
            if let error {
                MPLog.mapbox.error("MapsIndoors Mapbox style failed to load: \(error.localizedDescription)")
            }
            return
        }
        guard styleLoadFailed, error == nil else { return }
        styleLoadFailed = false
        adjustOrnaments()
        Task { @MainActor [weak self] in
            // reapplyVisibility() resets the world-state cache first — a style
            // (re)load reset the import config to defaults, so a plain
            // configure() would be a cache no-op here (SPEX-2097 + SPEX-2169).
            await self?.mapboxTransitionHandler?.reapplyVisibility()
        }
    }

    @MainActor
    private func _loadMapbox() async {
        if useMapsIndoorsStyle, NetworkPathMonitor.shared.isConnected {
            await loadMapsIndoorsStyleResumingOnce()
        }

        // Re-assert ornament adjustments after every load. The
        // `onStyleLoaded` observer also fires for the load awaited
        // above, but offline / `useMapsIndoorsStyle == false` paths
        // skip `loadStyle()` entirely — leaving the Mapbox logo
        // visible from the default style if we only relied on the
        // observer (SPEX-1786).
        adjustOrnaments()
        renderer?.cleanup()
        renderer = MBRenderer(mapView: mapView, provider: self)
        _routeRenderer = MBRouteRenderer(mapView: mapView)

        // Remove any previously added tap recognizer to prevent duplicates on reload
        if let existing = tapGestureRecognizer {
            mapView?.removeGestureRecognizer(existing)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(onMapClick))
        tapGestureRecognizer = tap
        mapView?.addGestureRecognizer(tap)

        // Cancel any previous camera observers to prevent accumulation on reload
        cameraChangedCancellable?.cancel()
        cameraIdleCancellable?.cancel()

        cameraChangedCancellable = mapView?.mapboxMap.onCameraChanged.observe { [weak self] _ in
            guard let self else { return }
            self._cameraDebounceTask?.cancel()
            // @MainActor: cameraChangedPosition() reads main-thread-only state
            // (e.g. cameraPosition, which traps off-main). Without this, the
            // Task resumes on the cooperative pool after the sleep and the
            // delegate call would trap on every camera change.
            self._cameraDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms debounce
                guard Task.isCancelled == false else { return }
                self?.delegate?.cameraChangedPosition()
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
        cameraIdleCancellable = mapView?.mapboxMap.onMapIdle.observe { [weak self] _ in
            guard let self else { return }
            if self.latestIdleTime.timeIntervalSinceNow < -0.5 {
                self.latestIdleTime = Date.now
                Task.detached(priority: .userInitiated) { [weak self] in
                    self?.delegate?.cameraIdle()
                }
            }
        }

        // Set flags for certain MapsIndoors features (which require specific MapsIndoors licenses to utilize)
        if let r = renderer {
            configureMapsIndoorsModuleLicensing(map: mapView?.mapboxMap, renderer: r)
        }
        positionPresenter = MBPositionPresenter(map: mapView?.mapboxMap)

        if let tileProvider = tileProvider?._tileProvider {
            await setTileProvider(tileProvider: tileProvider)
        }

        await mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisibility()

        await setViewModels(models: [], forceClear: true)
    }

    @objc func onMapClick(_ sender: UITapGestureRecognizer) {
        let screenPoint = sender.location(in: mapView)
        guard let mapboxMap = mapView?.mapboxMap else { return }

        let queryOptions = RenderedQueryOptions(
            layerIds: [
                Constants.LayerIDs.routeMarkerLayer,
                Constants.LayerIDs.markerLayer,
                Constants.LayerIDs.markerNoCollisionLayer,
                Constants.LayerIDs.flatLabelsLayer,
                Constants.LayerIDs.graphicLabelsLayer,
                Constants.LayerIDs.model3DLayer,
                Constants.LayerIDs.polygonFillLayer,
                Constants.LayerIDs.wallExtrusionLayer,
                Constants.LayerIDs.featureExtrusionLayer,
            ], filter: nil)

        // Tolerance rect for pass 2, or nil when the host app has opted out of the expanded tap
        // area — in which case a tap has to land on the feature itself.
        let tapRect = Self.tapQueryRect(around: screenPoint, expanded: expandedTapAreaEnabled)

        let coordinateFallback: () -> Void = { [weak self] in
            guard let self, let coordinate = self.mapView?.mapboxMap.coordinate(for: screenPoint) else { return }
            self.delegate?.didTap(coordinate: coordinate)
        }

        // Pass 1: exact hit under the finger (zero-tolerance point query). When
        // the tap lands directly on a room/marker, that feature must win — the
        // wide tolerance rect (pass 2) can cover several neighbouring rooms when
        // zoomed out, and the query result is not ordered by distance, so falling
        // straight to it would select an arbitrary neighbour (SPEX-1903).
        mapboxMap.queryRenderedFeatures(with: screenPoint, options: queryOptions) { [weak self] pointResult in
            guard let self else { return }
            if case .success(let features) = pointResult, self.dispatchTap(features, screenPoint: screenPoint, map: mapboxMap) { return }

            // Pass 2: widen to the tolerance rect (preserves the SPEX-1611 fix). Absent when the
            // expanded tap area is disabled, so an off-target tap reports a bare coordinate.
            guard let tapRect else {
                coordinateFallback()
                return
            }
            mapboxMap.queryRenderedFeatures(with: tapRect, options: queryOptions) { [weak self] rectResult in
                guard let self else { return }
                if case .success(let features) = rectResult, self.dispatchTap(features, screenPoint: screenPoint, map: mapboxMap) { return }
                coordinateFallback()
            }
        }
    }

    /// Screen-space padding added around a tap before re-querying, in points.
    /// 22pt is half of Apple's 44pt minimum touch target.
    static let tapTolerance: CGFloat = 22

    /// The rect to re-query when nothing was found directly under the finger, or `nil` when the
    /// expanded tap area is disabled.
    ///
    /// Centred on the tap and `tapTolerance` in every direction. Reaching *up* is what makes a
    /// bottom-anchored icon tappable at all, since such an icon renders above its coordinate and can
    /// leave nothing under the finger (SPEX-1611). The rect is symmetric, so it reaches equally far
    /// *down* — which is why a map with large, densely placed icons may want it off: there, a tap in
    /// open space can still land within tolerance of an icon drawn above it.
    ///
    /// Extracted so both the geometry and the opt-out are unit-testable without a live map; see
    /// `MapBoxProviderTapToleranceTests`.
    static func tapQueryRect(around point: CGPoint, expanded: Bool) -> CGRect? {
        guard expanded else { return nil }
        return CGRect(
            x: point.x - tapTolerance,
            y: point.y - tapTolerance,
            width: tapTolerance * 2,
            height: tapTolerance * 2)
    }

    /// A tap candidate reduced to the only fields the selection ranking needs.
    /// Decoupling the ranking from Mapbox's `QueriedRenderedFeature` (which has
    /// no public initializer) keeps `selectedCandidateIndex` unit-testable — see
    /// `MapBoxProviderTapSelectionTests`.
    struct TapCandidate {
        let id: String?
        let isMarker: Bool
        let clickable: Bool
        let screenDistance: CGFloat
    }

    /// How far a marker may sit from its own coordinate and still count as a direct hit, when the
    /// expanded tap area is off.
    ///
    /// `configureMarkerLayer` gives the marker layers a `textField`, so a floating label is part of
    /// the same symbol as its icon and a rendered query returns the marker for a tap on the text.
    /// Measured on Temple Square: icon taps report 11-33pt, label taps 66-136pt.
    ///
    /// Assumes an icon drawn within 44pt of its coordinate. Icon size and anchor come from the
    /// display rule, so a solution with larger bottom-anchored icons will lose taps near the top of
    /// its own icons while opted out. Deriving the bound from icon size is not possible today —
    /// size is not among the feature properties.
    static var directHitTolerance: CGFloat { tapTolerance * 2 }

    /// The marker bound for a tap, or `nil` while the expanded tap area is on.
    ///
    /// Extracted for the same reason as `tapQueryRect(around:expanded:)`: it puts the step from the
    /// public flag to the bound under test, which a device pass would otherwise be the only thing
    /// covering. `dispatchTap` as a whole stays untestable — `QueriedRenderedFeature` has no public
    /// initialiser — but this part of it does not have to.
    static func markerDistanceCap(expanded: Bool) -> CGFloat? {
        expanded ? nil : directHitTolerance
    }

    /// Index of the candidate a tap should select: among clickable, identified
    /// candidates, the nearest marker — the icon the user aims at — otherwise
    /// the nearest candidate of any kind. `nil` if none qualify.
    ///
    /// `queryRenderedFeatures` returns features in render (paint) order, NOT by
    /// distance from the tap. Dispatching the first clickable hit therefore
    /// selected an arbitrary neighbouring room when several fell inside the
    /// tolerance rect (zoomed out / pitched) — SPEX-1903. Ranking by screen
    /// distance makes the room actually under the finger win.
    ///
    /// - Parameter maxMarkerDistance: when set, a **marker** further than this from the tap is
    ///   discarded before ranking.
    ///
    ///   Markers only: a rendered query returns a feature whose drawn form covers the tap, so for a
    ///   room or a model that form *is* the location and the distance means nothing. Only a marker
    ///   is ambiguous, because its icon and label are one symbol.
    ///
    ///   A discarded marker does not consume the tap — `markers` empties, the pool falls back to
    ///   the non-markers, and the tap selects what is drawn underneath (indoors, usually the room
    ///   the label overhangs). Deliberate: the alternative puts a silent dead zone wherever a label
    ///   crosses a feature. An earlier revision that bound every point geometry showed the cost —
    ///   tapping a building discarded its only candidate and selected nothing. Pinned by
    ///   `labelFallsThroughToRoom` and `labelFallsThroughToModel`.
    ///
    ///   Route pins are never bound: `createRouteMarkerViewModel` never sets `.type`, so they
    ///   resolve to `.undefined`. Kept that way — see the comment there.
    static func selectedCandidateIndex(
        _ candidates: [TapCandidate], maxMarkerDistance: CGFloat? = nil
    ) -> Int? {
        let eligible = candidates.indices.filter {
            guard candidates[$0].clickable, candidates[$0].id != nil else { return false }
            guard let cap = maxMarkerDistance, candidates[$0].isMarker else { return true }
            return candidates[$0].screenDistance <= cap
        }
        let markers = eligible.filter { candidates[$0].isMarker }
        let pool = markers.isEmpty ? eligible : markers
        return pool.min { candidates[$0].screenDistance < candidates[$1].screenDistance }
    }

    /// Forwards the clickable feature nearest the tap to the appropriate delegate
    /// (route marker vs. location). Returns `true` if a feature was dispatched,
    /// so the caller can stop before widening the query / falling back to a bare
    /// coordinate tap. Ranking lives in `selectedCandidateIndex`.
    private func dispatchTap(_ features: [QueriedRenderedFeature], screenPoint: CGPoint, map: MapboxMap) -> Bool {
        let candidates = features.map { result -> TapCandidate in
            let id: String? = {
                if case .string(let string)? = result.queriedFeature.feature.identifier { return string }
                return nil
            }()
            return TapCandidate(
                id: id,
                isMarker: result.queriedFeature.mpRenderedFeatureType == .marker,
                clickable: result.queriedFeature.feature.properties?["clickable"] != JSONValue(booleanLiteral: false),
                screenDistance: screenDistance(of: result.queriedFeature.feature, to: screenPoint, map: map))
        }

        guard
            let index = Self.selectedCandidateIndex(
                candidates, maxMarkerDistance: Self.markerDistanceCap(expanded: expandedTapAreaEnabled))
        else { return false }
        let result = features[index]
        guard case .string(let idString)? = result.queriedFeature.feature.identifier else { return false }

        if idString == "end_marker" || idString == "start_marker" || idString.starts(with: "stop") {
            routeRenderer.routeMarkerDelegate?.onRouteMarkerClicked(tag: idString)
        } else {
            _ = delegate?.didTap(locationId: String(idString), type: result.queriedFeature.mpRenderedFeatureType)
        }
        return true
    }

    /// Screen-space distance (points) from `screenPoint` to the nearest vertex
    /// of `feature`'s geometry. Used to rank tap candidates by proximity.
    private func screenDistance(of feature: Feature, to screenPoint: CGPoint, map: MapboxMap) -> CGFloat {
        func distance(to coordinate: CLLocationCoordinate2D) -> CGFloat {
            let point = map.point(for: coordinate)
            let dx = point.x - screenPoint.x
            let dy = point.y - screenPoint.y
            return (dx * dx + dy * dy).squareRoot()
        }
        switch feature.geometry {
        case .point(let point):
            return distance(to: point.coordinates)
        case .polygon(let polygon):
            return polygon.coordinates.flatMap { $0 }.map(distance).min() ?? .greatestFiniteMagnitude
        case .multiPolygon(let multiPolygon):
            return multiPolygon.coordinates.flatMap { $0 }.flatMap { $0 }.map(distance).min() ?? .greatestFiniteMagnitude
        case .lineString(let lineString):
            return lineString.coordinates.map(distance).min() ?? .greatestFiniteMagnitude
        default:
            return .greatestFiniteMagnitude
        }
    }

    func onInfoWindowTapped(locationId: String) {
        _ = delegate?.didTapInfoWindowOf(locationId: locationId)
    }

    /// Offset from the logo's margins to the attribution ornament's, so the info **glyph** lines up with the
    /// logo rather than the ornament's frame doing so.
    ///
    /// Mapbox wraps a system `.infoLight` button in a 44pt tap target and bottom-aligns the glyph inside it,
    /// so the frame is wider and taller than what is seen: `x` pulls back the horizontal overhang, `y` centres
    /// the glyph on the logo instead of leaving the two bottom-aligned.
    ///
    /// `bounds` for the ornament, not `intrinsicContentSize`: it is sized by constraints and reports none.
    ///
    /// Internal (not `private`) so tests can exercise the arithmetic with stub views — it needs no live map.
    @MainActor
    static func attributionOffset(fromLogo logo: UIView, ornament: UIView) -> CGPoint {
        let glyph = UIButton(type: .infoLight).intrinsicContentSize
        let logoSize = logo.intrinsicContentSize
        let horizontalOverhang = max(0, (ornament.bounds.width - glyph.width) / 2)
        return CGPoint(
            x: logoSize.width - horizontalOverhang,
            y: (logoSize.height - glyph.height) / 2)
    }

    @MainActor
    private func adjustOrnaments() {
        guard let mapView else { return }

        let bottomPadding = padding.bottom + 5
        mapView.ornaments.options.scaleBar.visibility = .hidden

        let logoView = mapView.ornaments.logoView
        let attributionButton = mapView.ornaments.attributionButton

        if hideMapboxLogo {
            // Hide the Mapbox logo AND its attribution "i" button together; the
            // MapsPeople logo then takes over the bottom-left slot (see
            // `mapsPeopleLogoPosition`). This matches the JS SDK's
            // `hideProviderLogo` and the Android adapter. Consuming apps are
            // responsible for confirming they hold the contractual right with
            // Mapbox to suppress the logo/attribution.
            //
            // Hide via `isHidden` only (no `removeFromSuperview()`): detaching the
            // views drops the Auto Layout constraints `OrnamentsManager` created
            // for them, so they can't be cleanly restored if the flag is later
            // toggled back to shown. Durability across style reloads is instead
            // guaranteed by `adjustOrnaments()` being re-invoked on every path
            // that can surface the ornaments — init, the `onStyleLoaded` observer,
            // and padding changes (see SPEX-1786) — which re-hides the fresh views
            // Mapbox rebuilds.
            logoView.isHidden = true
            attributionButton.isHidden = true
        } else {
            // Both shown: keep the Mapbox logo and its attribution "i" button
            // together on the bottom-left (the "i" is Mapbox's own attribution
            // control, so it belongs with the Mapbox logo), the button to the
            // RIGHT of the logo. The MapsPeople logo is anchored bottom-right
            // (see `mapsPeopleLogoPosition`).
            //
            // The attribution button takes the logo's margins plus the offset
            // that lines its glyph up with the logo. It cannot reuse its own
            // margin: Mapbox defaults it to bottom-TRAILING, so that x is an
            // inset from the right edge and reapplying it on the left drops the
            // "i" onto the logo — the bug. Every input is either written back
            // unchanged or intrinsic, so re-running this on each style load and
            // padding change recomputes the same point.
            logoView.isHidden = false
            attributionButton.isHidden = false

            let logoLeftMargin = mapView.ornaments.options.logo.margins.x
            mapView.ornaments.options.logo.position = .bottomLeft
            mapView.ornaments.options.logo.margins = CGPoint(x: logoLeftMargin, y: bottomPadding)

            let attributionOffset = Self.attributionOffset(fromLogo: logoView, ornament: attributionButton)

            mapView.ornaments.options.attributionButton.position = .bottomLeft
            mapView.ornaments.options.attributionButton.margins = CGPoint(
                x: logoLeftMargin + attributionOffset.x, y: bottomPadding + attributionOffset.y)
        }
    }

    @MainActor
    private func configureMapsIndoorsModuleLicensing(map _: MapboxMap?, renderer: MBRenderer) {
        do {
            if let solutionModules = MPMapsIndoors.shared.solution?.modules {
                if solutionModules.contains("z22") {
                    try mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 25))
                } else {
                    try mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 21))
                }
                renderer.isWallExtrusionsEnabled = solutionModules.contains("3dwalls")
                renderer.isFeatureExtrusionsEnabled = solutionModules.contains("3dextrusions")
                renderer.is2dModelsEnabled = solutionModules.contains("2dmodels")
                renderer.isFloorPlanEnabled = solutionModules.contains("floorplan")
            }
            try mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions())
        } catch {}
    }

    private func registerLocalFallbackFontWith(filenameString: String, bundleIdentifierString _: String) {
        guard let bundle = MapsIndoorsBundle.bundle else {
            MPLog.mapbox.debug("Failed to register font - bundle identifier invalid.")
            return
        }
        guard let pathForResourceString = bundle.path(forResource: filenameString, ofType: nil),
            let fontData = NSData(contentsOfFile: pathForResourceString),
            let dataProvider = CGDataProvider(data: fontData),
            let fontRef = CGFont(dataProvider)
        else { return }

        var errorRef: Unmanaged<CFError>? = nil
        if CTFontManagerRegisterGraphicsFont(fontRef, &errorRef) == false {
            /// Already-registered is expected on second and subsequent map instances since the font is registered process-wide; only surface other errors.
            let code = errorRef.map { CFErrorGetCode($0.takeRetainedValue()) }
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                MPLog.mapbox.debug("Failed to register font '\(filenameString)': code \(code ?? -1)")
            }
        }
    }

    public func applyClippingGeometries(_ geometries: [MPPolygonGeometry]) async {
        let isClippingAllowed = MPMapsIndoors.shared.solution?.modules.contains("cliplayer") ?? false
        guard let mapView = mapView, isClippingAllowed == true else { return }

        var features = [Feature]()
        for geometry in geometries {
            let coordinates = geometry.coordinates.map { $0.map(\.coordinate) }
            let feature = Feature(geometry: Polygon(coordinates))
            features.append(feature)
        }

        let newGeoJSON: GeoJSONObject = .featureCollection(FeatureCollection(features: features)).geoJSONObject

        await MainActor.run {
            mapView.mapboxMap?.updateGeoJSONSource(
                withId: Constants.SourceIDs.clippingSource,
                geoJSON: newGeoJSON)
        }
    }
}

extension QueriedFeature {
    fileprivate var mpRenderedFeatureType: MPRenderedFeatureType {
        if let typeString = (feature.properties?["type"] as? JSONValue)?.rawValue as? String,
            let type = MPRenderedFeatureType(rawValue: typeString)
        {
            return type
        }
        return .undefined
    }
}
