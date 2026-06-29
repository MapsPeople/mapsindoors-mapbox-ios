import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoors
@_spi(Private) import MapsIndoorsCore

public class MapBoxProvider: MPMapProvider {
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

    public var transitionLevel = 17

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

    /// Controls visibility of the Mapbox logo (watermark).
    /// `false` (the default, matching the Android SDK's `hideMapboxLogo`
    /// builder option) shows the Mapbox logo in its default slot; `true`
    /// suppresses it and lets the MapsPeople branding logo take over the
    /// bottom-left watermark slot. Re-applies on the main actor because
    /// `adjustOrnaments()` touches UIKit ornament views.
    public var hideMapboxLogo: Bool = false {
        didSet {
            guard oldValue != hideMapboxLogo else { return }
            MainActor.assumeIsolated { adjustOrnaments() }
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

    private var renderer: MBRenderer?

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

    public var padding: UIEdgeInsets = .zero {
        // `padding` is set from `MPMapControlInternal` on the main
        // thread — UIKit anyway — but the setter has no isolation in
        // its signature, so assert before hopping into the
        // @MainActor-only `adjustOrnaments()`.
        didSet { MainActor.assumeIsolated { adjustOrnaments() } }
    }

    public var mpAccessibilityElementsHidden: Bool = false

    public weak var delegate: MPMapProviderDelegate?

    public var positionPresenter: MPPositionPresenter

    public var collisionHandling: MPCollisionHandling = .allowOverLap

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

        // Serialize renders: cancel and await the predecessor so its task-group
        // children release their `MPViewModel` captures before we hand a new
        // models array to the renderer. Renderer property assignments are done
        // *after* this barrier so the predecessor's in-flight render cannot
        // observe mid-flight mutation of these settings.
        let previous = renderTask
        previous?.cancel()
        await previous?.value

        // Ignore `forceClear` - not applicable to mapbox rendering
        renderer?.customInfoWindow = customInfoWindow
        renderer?.collisionHandling = collisionHandling
        renderer?.featureExtrusionOpacity = featureExtrusionOpacity
        renderer?.wallExtrusionOpacity = wallExtrusionOpacity

        let task = Task { @MainActor [weak self] in
            do {
                try await self?.renderer?.render(models: models)
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
        }

        Task { [weak self] in
            await self?.verifySetup()
        }

        registerLocalFallbackFontWith(filenameString: "OpenSans-Bold.ttf", bundleIdentifierString: "Fonts")
    }

    private let styleUrl = "mapbox://styles/mapspeople/clrakuu6s003j01pf11uz5d45"

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

    @MainActor
    private func _loadMapbox() async {
        if useMapsIndoorsStyle, NetworkPathMonitor.shared.isConnected {
            await withCheckedContinuation { [weak self] continuation in
                guard let self else {
                    continuation.resume()
                    return
                }
                mapView?.mapboxMap.loadStyle(StyleURI(url: URL(string: styleUrl)!)!) { _ in
                    continuation.resume()
                }
            }
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
            self._cameraDebounceTask = Task { [weak self] in
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

        // Tolerance rect: catches bottom-anchored / small icons whose visual
        // offset leaves nothing exactly under the finger (the SPEX-1611
        // "markers sometimes not clickable" fix). 22pt ≈ Apple's 44pt target.
        let tapTolerance: CGFloat = 22
        let tapRect = CGRect(
            x: screenPoint.x - tapTolerance,
            y: screenPoint.y - tapTolerance,
            width: tapTolerance * 2,
            height: tapTolerance * 2)

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

            // Pass 2: widen to the tolerance rect (preserves the SPEX-1611 fix).
            mapboxMap.queryRenderedFeatures(with: tapRect, options: queryOptions) { [weak self] rectResult in
                guard let self else { return }
                if case .success(let features) = rectResult, self.dispatchTap(features, screenPoint: screenPoint, map: mapboxMap) { return }
                coordinateFallback()
            }
        }
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

    /// Index of the candidate a tap should select: among clickable, identified
    /// candidates, the nearest marker — the icon the user aims at — otherwise
    /// the nearest candidate of any kind. `nil` if none qualify.
    ///
    /// `queryRenderedFeatures` returns features in render (paint) order, NOT by
    /// distance from the tap. Dispatching the first clickable hit therefore
    /// selected an arbitrary neighbouring room when several fell inside the
    /// tolerance rect (zoomed out / pitched) — SPEX-1903. Ranking by screen
    /// distance makes the room actually under the finger win.
    static func selectedCandidateIndex(_ candidates: [TapCandidate]) -> Int? {
        let eligible = candidates.indices.filter { candidates[$0].clickable && candidates[$0].id != nil }
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

        guard let index = Self.selectedCandidateIndex(candidates) else { return false }
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
            // control, so it belongs with the Mapbox logo). They share the same
            // left margin; Mapbox's `OrnamentsManager` lays the attribution out
            // relative to the logo on that corner. The MapsPeople logo is
            // anchored bottom-right (see `mapsPeopleLogoPosition`).
            logoView.isHidden = false
            attributionButton.isHidden = false

            let logoLeftMargin = mapView.ornaments.options.logo.margins.x
            mapView.ornaments.options.logo.position = .bottomLeft
            mapView.ornaments.options.logo.margins = CGPoint(x: logoLeftMargin, y: bottomPadding)

            mapView.ornaments.options.attributionButton.position = .bottomLeft
            mapView.ornaments.options.attributionButton.margins = CGPoint(x: logoLeftMargin, y: bottomPadding)
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
