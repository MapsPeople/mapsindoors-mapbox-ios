import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoors
@_spi(Private) import MapsIndoorsCore

public class MapBoxProvider: MPMapProvider {
    public let model2DResolutionLimit = 500

    public var enableNativeMapBuildings: Bool = true {
        didSet {
            mapboxTransitionHandler?.enableMapboxBuildings = enableNativeMapBuildings
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
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
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
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
            }
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

    /// Mapbox's own logo is hidden in `adjustOrnaments()`; we relocate the
    /// MapsPeople branding logo to the bottom-left to fill the role of the
    /// map watermark, and the Mapbox attribution button shifts right of it.
    public var mapsPeopleLogoPosition: MPMapsPeopleLogoPosition { .bottomLeft }

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
        MPLogger.sharedInstance.setMapProviderLogIdentity(MBProviderLogIdentity())
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

        // Ornament adjustment is owned by the `onStyleLoaded` observer
        // installed in `init` — it fires for every style load, including
        // the one we just awaited above and any later style swaps. No
        // need to call `adjustOrnaments()` directly here.
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
                await self?.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
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

        await mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()

        await setViewModels(models: [], forceClear: true)
    }

    @objc func onMapClick(_ sender: UITapGestureRecognizer) {
        let screenPoint = sender.location(in: mapView)

        // Use a small rect around the tap point to account for icon anchor offsets and to matches Apple's minimum touch target.
        let tapTolerance: CGFloat = 22
        let tapRect = CGRect(
            x: screenPoint.x - tapTolerance,
            y: screenPoint.y - tapTolerance,
            width: tapTolerance * 2,
            height: tapTolerance * 2)

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

        mapView?.mapboxMap.queryRenderedFeatures(with: tapRect, options: queryOptions) { result in
            if case .success(let queriedFeatures) = result {
                for result in queriedFeatures {
                    if result.queriedFeature.feature.properties?["clickable"] == JSONValue(booleanLiteral: false) {
                        continue
                    }

                    guard let id = result.queriedFeature.feature.identifier, case .string(let idString) = id else { continue }

                    if idString == "end_marker" || idString == "start_marker" || idString.starts(with: "stop") {
                        self.routeRenderer.routeMarkerDelegate?.onRouteMarkerClicked(tag: idString)
                        return
                    } else {
                        _ = self.delegate?.didTap(locationId: String(idString), type: result.queriedFeature.mpRenderedFeatureType)
                        return
                    }
                }
            }

            if let coordinate = self.mapView?.mapboxMap.coordinate(for: screenPoint) {
                self.delegate?.didTap(coordinate: coordinate)
            }
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

        // Hide the Mapbox logo (watermark).
        //
        // ⚠️  COMPLIANCE NOTE
        //  The Mapbox Terms of Service ("Maps SDK Service Specific Terms")
        //  require that the Mapbox logo and attribution remain visible on
        //  any map rendering Mapbox tiles. Hiding the logo without an
        //  enterprise / no-attribution rider in the consuming app's Mapbox
        //  contract puts that app in breach of Mapbox's ToS. The Mapbox
        //  attribution button below is intentionally left visible so the
        //  legally required source attribution (OpenStreetMap, imagery
        //  providers, etc.) remains accessible to end users.
        //
        //  Consuming apps that ship this build are responsible for confirming
        //  they have the contractual right with Mapbox to suppress the logo.
        //
        //  Implementation note: Mapbox v11 marks `OrnamentOptions.logo.visibility`
        //  as @_spi (private API). Toggling `UIView.isHidden` on the
        //  underlying `logoView` alone is not durable — `OrnamentsManager`
        //  rebuilds and re-lays out its subviews on style reloads and
        //  resets the flag. Detach the view from the hierarchy and hide it
        //  for belt-and-suspenders coverage; `adjustOrnaments()` is
        //  re-invoked from the `onStyleLoaded` observer so a fresh
        //  logoView produced after a style swap is also suppressed.
        let logoView = mapView.ornaments.logoView
        logoView.isHidden = true
        logoView.removeFromSuperview()

        // Position the attribution button at the bottom-left, offset to
        // the right of the MapsPeople branding logo (which now occupies
        // the watermark slot vacated by the hidden Mapbox logo). The
        // logo width and the spacing both come from
        // MPMapsPeopleLogoLayout so this provider and MPMapControl stay
        // in sync via a single source of truth.
        let attributionLeftOffset = MPMapsPeopleLogoLayout.width + MPMapsPeopleLogoLayout.trailingSpacing
        mapView.ornaments.options.attributionButton.position = .bottomLeft
        mapView.ornaments.options.attributionButton.margins = CGPoint(x: attributionLeftOffset, y: bottomPadding)
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
