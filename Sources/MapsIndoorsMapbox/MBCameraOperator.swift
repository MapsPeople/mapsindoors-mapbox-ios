//
//  MBCameraOperator.swift
//  MapsIndoorsMapbox
//
//  Created by Frederik Hansen on 08/09/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapsIndoorsCore
import MapboxMaps


class MBCameraOperator: MPCameraOperator {
    
    weak var map: MapboxMap?
    weak var view: MapView?
    weak var mapProvider: MPMapProvider?
    
    required init(mapView: MapView, provider: MPMapProvider) {
        map = mapView.mapboxMap
        view = mapView
        mapProvider = provider
    }
    
    init() { }
    
    func move(target: CLLocationCoordinate2D, zoom: Float) {
        self.view?.mapboxMap.setCamera(to: CameraOptions(center: target, zoom: CGFloat(zoom)))
    }
    
    func animate(pos: MPCameraPosition) {
        DispatchQueue.main.async {
            let newCamera = CameraOptions(center: CLLocationCoordinate2D(latitude: pos.target.latitude, longitude: pos.target.longitude),
                                          zoom: CGFloat(pos.zoom),
                                          bearing: pos.bearing,
                                          pitch: pos.viewingAngle)
            self.view?.camera.ease(to: newCamera, duration: 0.3)
        }
    }
    
    func animate(bounds: MPGeoBounds) {
        DispatchQueue.main.async { [self] in
            do {
                if let newCamera = try view?.mapboxMap.camera(for: [bounds.southWest, bounds.northEast], camera: CameraOptions(), coordinatesPadding: mapProvider?.padding, maxZoom: nil, offset: nil) {
                    self.view?.camera.ease(to: newCamera, duration: 0.3)
                }
            } catch {
                MPLog.mapbox.error("Error trying to animate mapbox camera to bounds!")
            }
        }
    }
    
    func animate(target: CLLocationCoordinate2D, zoom: Float?) {
        DispatchQueue.main.async {
            let curZoom: Float? = if let z = self.view?.mapboxMap.cameraState.zoom {
                Float(z)
            } else {
                nil
            }
            if let zoom = zoom ?? curZoom {
                let newCamera = CameraOptions(center: target,
                                              zoom: CGFloat(zoom))
                self.view?.camera.ease(to: newCamera, duration: 0.3)
            }
        }
    }
    
    var position: MPCameraPosition {
        guard let camState = map?.cameraState else { return MBCameraPosition(cameraPosition: CameraOptions()) }
            
        return MBCameraPosition(cameraPosition: CameraOptions(cameraState: camState))
    }

    var projection: MPProjection {
        @MainActor
        get async {
            return MBProjectionModel(view: view)
        }
    }
    
    func camera(for bounds: MPGeoBounds, inserts: UIEdgeInsets) -> MPCameraPosition {
        do {
            let mbCameraForBounds = try view?.mapboxMap.camera(for: [bounds.southWest, bounds.northEast], camera: CameraOptions(), coordinatesPadding: inserts, maxZoom: nil, offset: nil)
            
            let cameraOptions = CameraOptions(
                center: mbCameraForBounds?.center,
                zoom: mbCameraForBounds?.zoom,
                bearing: mbCameraForBounds?.bearing,
                pitch: mbCameraForBounds?.pitch
            )
            
            return MBCameraPosition(cameraPosition: cameraOptions)
        } catch {
            MPLog.mapbox.error("Error trying to move mapbox camera to bounds!")
            return MBCameraPosition(cameraPosition: CameraOptions())
        }
    }
    
}
