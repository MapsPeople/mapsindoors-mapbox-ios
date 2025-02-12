import Foundation
import MapsIndoors
import MapsIndoorsCore
@_spi(Experimental) import MapboxMaps

public class MapBoxProvider: MPMapProvider {
    public let model2DResolutionLimit = 500

    public var enableNativeMapBuildings: Bool = true {
        didSet {
            mapboxTransitionHandler?.enableMapboxBuildings = enableNativeMapBuildings
        }
    }

    public var useMapsIndoorsStyle: Bool = true

    private var mapboxTransitionHandler: MapboxWorldTransitionHandler?

    public var transitionLevel = 17

    public var showMapboxMapMarkers: Bool?

    public var showMapboxRoadLabels: Bool?

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

    private weak var onStyleLoadedCancelable: Cancelable?

    @MainActor
    public func setTileProvider(tileProvider: MPTileProvider) async {
        self.tileProvider = MBTileProvider(mapView: mapView, tileProvider: tileProvider, mapProvider: self)
    }

    public func reloadTilesForFloorChange() {
        tileProvider?.update()
    }

    private var renderer: MBRenderer?

    private var layerSetup: MBLayerPrecendence?

    private var _routeRenderer: MBRouteRenderer?

    public weak var view: UIView?

    public var padding: UIEdgeInsets = .zero {
        didSet { adjustOrnaments() }
    }

    public var MPaccessibilityElementsHidden: Bool = false

    public weak var delegate: MPMapProviderDelegate?

    public var positionPresenter: MPPositionPresenter

    public var collisionHandling: MPCollisionHandling = .allowOverLap

    public var routeRenderer: MPRouteRenderer {
        _routeRenderer ?? MBRouteRenderer(mapView: mapView)
    }

    let d = DispatchQueue(label: "mdf", qos: .userInteractive)

    private var lastSetViewModels = [any MPViewModel]()
    public func setViewModels(models: [any MPViewModel], forceClear _: Bool) async {
        d.async {
            self.lastSetViewModels.removeAll(keepingCapacity: true)
            self.lastSetViewModels.append(contentsOf: models)
        }

        if let r = renderer {
            await configureMapsIndoorsModuleLicensing(map: mapView?.mapboxMap, renderer: r)
        }

        // Ignore `forceClear` - not applicable to mapbox rendering
        renderer?.customInfoWindow = customInfoWindow
        renderer?.collisionHandling = collisionHandling
        renderer?.featureExtrusionOpacity = featureExtrusionOpacity
        renderer?.wallExtrusionOpacity = wallExtrusionOpacity
        do {
            try await renderer?.render(models: models)
        } catch {}
    }

    public var cameraOperator: MPCameraOperator {
        guard let mapView else { return MBCameraOperator() }

        return MBCameraOperator(mapView: mapView, provider: self)
    }

    weak var mapView: MapView?

    private var accessToken: String

    private var performanceStatisticsCancelable: AnyCancelable?

    public required init(mapView: MapView, accessToken: String) {
        self.mapView = mapView
        view = mapView
        self.accessToken = accessToken
        positionPresenter = MBPositionPresenter(map: self.mapView?.mapboxMap)

        mapboxTransitionHandler = MapboxWorldTransitionHandler(mapProvider: self)

        onStyleLoadedCancelable = self.mapView?.mapboxMap.onStyleLoaded.observe { [self] _ in
            if useMapsIndoorsStyle == false {
                Task {
                    await self.verifySetup()
                }
            }
        }

        Task {
            await self.verifySetup()
        }
        
        registerLocalFallbackFontWith(filenameString: "OpenSans-Bold.ttf", bundleIdentifierString: "Fonts")
    }

    private let styleUrl = "mapbox://styles/mapspeople/clrakuu6s003j01pf11uz5d45"

    private var cameraChangedCancellable: AnyCancelable? = nil
    private var cameraIdleCancellable: AnyCancelable? = nil

    @MainActor
    private func verifySetup() async {
        await loadMapbox()
    }

    @MainActor
    public func loadMapbox() async {

        if useMapsIndoorsStyle && MPNetworkReachabilityManager.shared().isReachable {
            await withCheckedContinuation { continuation in
                mapView?.mapboxMap.loadStyle(StyleURI(url: URL(string: styleUrl)!)!) { _ in
                    continuation.resume()
                }
            }
        }

        adjustOrnaments()
        renderer = MBRenderer(mapView: mapView, provider: self)
        _routeRenderer = MBRouteRenderer(mapView: mapView)
        mapView?.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onMapClick)))

        cameraChangedCancellable = mapView?.mapboxMap.onCameraChanged.observe { _ in
            Task.detached(priority: .userInitiated) {
                self.delegate?.cameraChangedPosition()
                await self.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
            }
        }
        cameraIdleCancellable = mapView?.mapboxMap.onMapIdle.observe { _ in
            Task.detached(priority: .userInitiated) {
                self.delegate?.cameraIdle()
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

        var lastModels = [any MPViewModel]()
        d.sync {
            lastModels.append(contentsOf: self.lastSetViewModels)
        }

        await setViewModels(models: lastModels, forceClear: true)
    }

    @objc func onMapClick(_ sender: UITapGestureRecognizer) {
        let screenPoint = sender.location(in: mapView)

        let queryOptions = RenderedQueryOptions(layerIds: [
            Constants.LayerIDs.routeMarkerLayer,
            Constants.LayerIDs.markerLayer,
            Constants.LayerIDs.markerNoCollisionLayer,
            Constants.LayerIDs.flatLabelsLayer,
            Constants.LayerIDs.graphicLabelsLayer,
            Constants.LayerIDs.model3DLayer,
            Constants.LayerIDs.polygonFillLayer,
            Constants.LayerIDs.wallExtrusionLayer,
            Constants.LayerIDs.featureExtrusionLayer
        ], filter: nil)

        mapView?.mapboxMap.queryRenderedFeatures(with: screenPoint, options: queryOptions) { result in
            if case let .success(queriedFeatures) = result {
                for result in queriedFeatures {
                    if result.queriedFeature.feature.properties?["clickable"] == JSONValue(booleanLiteral: false) {
                        continue
                    }

                    guard let id = result.queriedFeature.feature.identifier, case let .string(idString) = id else { continue }

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

    private func adjustOrnaments() {
        guard let mapView else { return }

        let bottomPadding = padding.bottom + 5
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.logo.margins = CGPoint(x: 9, y: bottomPadding)
        mapView.ornaments.options.attributionButton.position = .bottomLeading

        let pos = mapView.ornaments.logoView.frame.width
        mapView.ornaments.options.attributionButton.margins = CGPoint(x: pos + 8, y: bottomPadding)
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
    
    private func registerLocalFallbackFontWith(filenameString: String, bundleIdentifierString: String) {
        if let bundle = MapsIndoorsBundle.bundle {
            let pathForResourceString = bundle.path(forResource: filenameString, ofType: nil)
            if let fontData = NSData(contentsOfFile: pathForResourceString!), let dataProvider = CGDataProvider.init(data: fontData) {
                let fontRef = CGFont.init(dataProvider)
                var errorRef: Unmanaged<CFError>? = nil
                if (CTFontManagerRegisterGraphicsFont(fontRef!, &errorRef) == false) {
                    print("Failed to register font - register graphics font failed - this font may have already been registered in the main bundle.")
                }
            }
        } else {
            print("Failed to register font - bundle identifier invalid.")
        }
    }
}

private extension QueriedFeature {
    var mpRenderedFeatureType: MPRenderedFeatureType {
        if let typeString = (feature.properties?["type"] as? JSONValue)?.rawValue as? String,
           let type = MPRenderedFeatureType(rawValue: typeString) {
            return type
        }
        return .undefined
    }
}
