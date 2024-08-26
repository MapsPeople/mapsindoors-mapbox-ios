//
//  MapBoxProvider.swift
//  MapsIndoorsMapbox
//
//  Created by Malte Myhlendorph on 20/07/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapsIndoorsCore
import MapboxMaps

public class MapBoxProvider: MPMapProvider {
    
    public let model2DResolutionLimit = 500
    
    public var enableNativeMapBuildings: Bool = true {
        didSet {
            self.mapboxTransitionHandler?.enableMapboxBuildings = self.enableNativeMapBuildings
        }
    }
    
    private var mapboxTransitionHandler: MapboxWorldTransitionHandler?
    
    public var transitionLevel = 17
    
    public var showMapboxMapMarkers: Bool?
    
    public var showMapboxRoadLabels: Bool?
    
    public var wallExtrusionOpacity: Double = 0
    
    public var featureExtrusionOpacity: Double = 0
    
    public var routingService: MPExternalDirectionsService {
        return MBDirectionsService(accessToken: self.accessToken)
    }
    
    public var distanceMatrixService: MPExternalDistanceMatrixService {
        return MBDistanceMatrixService(accessToken: self.accessToken)
    }
    
    public var customInfoWindow: MPCustomInfoWindow?
    
    private var tileProvider: MBTileProvider?
        
    private var onStyleLoadedCancelable: Cancelable?
    
    @MainActor
    public func setTileProvider(tileProvider: MPTileProvider) async {
        await verifySetup()
        self.tileProvider = MBTileProvider(mapView: mapView, tileProvider: tileProvider, mapProvider: self)
    }
    
    public func reloadTilesForFloorChange() {
        self.tileProvider?.update()
    }
    
    private var renderer: MBRenderer?
    
    private var layerSetup: MBLayerPrecendence?
    
    private var _routeRenderer: MBRouteRenderer?
    
    public weak var view: UIView?
    
    public var padding: UIEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) {
        didSet { adjustOrnaments() }
    }
    
    public var MPaccessibilityElementsHidden: Bool = false
    
    public weak var delegate: MPMapProviderDelegate?
    
    public var positionPresenter: MPPositionPresenter

    public var collisionHandling: MPCollisionHandling = .allowOverLap
    
    public var routeRenderer: MPRouteRenderer {
        return _routeRenderer ?? MBRouteRenderer(mapView: self.mapView)
    }
    
    private var lastSetViewModels = [any MPViewModel]()
    public func setViewModels(models: [any MPViewModel], forceClear: Bool) async {
        lastSetViewModels.removeAll(keepingCapacity: true)
        lastSetViewModels.append(contentsOf: models)
        
        if let r = renderer {
            await configureMapsIndoorsModuleLicensing(map: mapView?.mapboxMap, renderer: r)
        }
        
        await verifySetup()
        
        // Ignore `forceClear` - not applicable to mapbox rendering
        renderer?.customInfoWindow = customInfoWindow
        renderer?.collisionHandling = self.collisionHandling
        renderer?.featureExtrusionOpacity = featureExtrusionOpacity
        renderer?.wallExtrusionOpacity = wallExtrusionOpacity
        self.renderer?.render(models: models)
    }
    
    public var cameraOperator: MPCameraOperator {
        guard let mapView else { return MBCameraOperator() }
        
        return MBCameraOperator(mapView: mapView, provider: self)
    }
    
    weak var mapView: MapView?
    
    private var accessToken: String
    
    public required init(mapView: MapView, accessToken: String) {
        self.mapView = mapView
        self.view = mapView
        self.accessToken = accessToken
        self.positionPresenter = MBPositionPresenter(map: self.mapView?.mapboxMap)
        
        mapboxTransitionHandler = MapboxWorldTransitionHandler(mapProvider: self)
        
        self.onStyleLoadedCancelable = mapView.mapboxMap.onStyleLoaded.observe { style in
            if self.mapView?.mapboxMap.styleURI?.rawValue != self.styleUrl {
                Task {
                    await self.verifySetup()
                }
            }
        }
        
        Task {
            await self.verifySetup()
        }
    }
    
    private let styleUrl = "mapbox://styles/mapspeople/clrakuu6s003j01pf11uz5d45"
    
    private var cameraChangedCancellable: AnyCancelable? = nil
    private var cameraIdleCancellable: AnyCancelable? = nil
    
    
    @MainActor
    private func verifySetup() async {
        if (self.mapView?.mapboxMap.isStyleLoaded ?? false) && mapView?.mapboxMap.styleURI?.rawValue == styleUrl {
            return
        }
        await self.loadMapbox()
    }
    
    
    @MainActor
    public func loadMapbox() async {
        guard mapView?.mapboxMap.styleURI?.rawValue != styleUrl else {
            return
        }
        
        await withCheckedContinuation { continuation in
            mapView?.mapboxMap.loadStyle(StyleURI(url: URL(string: styleUrl)!)!) { _ in
                continuation.resume()
            }
        }
        
        adjustOrnaments()
        renderer = MBRenderer(mapView: mapView, provider: self)
        _routeRenderer = MBRouteRenderer(mapView: self.mapView)
        mapView?.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onMapClick)))
        
        self.cameraChangedCancellable = mapView?.mapboxMap.onCameraChanged.observe { _ in
            Task.detached(priority: .userInitiated) {
                self.delegate?.cameraChangedPosition()
                await self.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
            }
        }
        cameraIdleCancellable = mapView?.mapboxMap.onMapIdle.observe({ _ in
            Task.detached(priority: .userInitiated) {
                self.delegate?.cameraIdle()
            }
        })
        
        // Set flags for certain MapsIndoors features (which require specific MapsIndoors licenses to utilize)
        if let r = renderer {
            configureMapsIndoorsModuleLicensing(map: mapView?.mapboxMap, renderer: r)
        }
        positionPresenter = MBPositionPresenter(map: mapView?.mapboxMap)
        
        if let tileProvider = tileProvider?._tileProvider {
            await setTileProvider(tileProvider: tileProvider)
        }
        
        await self.mapboxTransitionHandler?.configureMapsIndoorsVsMapboxVisiblity()
                
        await setViewModels(models: self.lastSetViewModels, forceClear: true)
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
        _ = self.delegate?.didTapInfoWindowOf(locationId: locationId)
    }
    
    private func adjustOrnaments() {
        guard let mapView else { return }
        
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.logo.margins = .init(x: 20, y: padding.bottom)
        mapView.ornaments.options.attributionButton.position = .bottomLeading
        
        let pos = mapView.ornaments.logoView.frame.width
    
        mapView.ornaments.options.attributionButton.margins = .init(x: pos + 20, y: padding.bottom)
        
    }
    
    @MainActor
    private func configureMapsIndoorsModuleLicensing(map: MapboxMap?, renderer: MBRenderer) {
        do {
            if let solutionModules = MPMapsIndoors.shared.solution?.modules {
                if solutionModules.contains("z22") {
                    try self.mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 25))
                } else {
                    try self.mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: 21))
                }
                renderer.isWallExtrusionsEnabled = solutionModules.contains("3dwalls")
                renderer.isFeatureExtrusionsEnabled = solutionModules.contains("3dextrusions")
                renderer.is2dModelsEnabled = solutionModules.contains("2dmodels")
                renderer.isFloorPlanEnabled = solutionModules.contains("floorplan")
            }
            try self.mapView?.mapboxMap.setCameraBounds(with: CameraBoundsOptions())
        } catch { }
    }
}

fileprivate extension QueriedFeature {
    
    var mpRenderedFeatureType: MPRenderedFeatureType {
        if let typeString = (self.feature.properties?["type"] as? JSONValue)?.rawValue as? String,
           let type = MPRenderedFeatureType(rawValue: typeString) {
            return type
        }
        return .undefined
    }
    
}
