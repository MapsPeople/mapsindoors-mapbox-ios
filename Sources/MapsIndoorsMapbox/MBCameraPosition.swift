//
//  MBCameraPositionModel.swift
//  MapsIndoorsMapbox
//
//  Created by Malte Myhlendorph on 20/07/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapsIndoorsCore
import MapboxMaps

class MBCameraPosition: MPCameraPosition {
    
    private var mapBoxCameraPosition: CameraOptions
    
    var target: CLLocationCoordinate2D {
        mapBoxCameraPosition.center ?? CLLocationCoordinate2D()
    }
    
    var zoom: Float {
        Float(mapBoxCameraPosition.zoom ?? 0) + 1
    }
    
    var bearing: CLLocationDirection {
        mapBoxCameraPosition.bearing ?? 0
    }
    
    var viewingAngle: Double {
        mapBoxCameraPosition.pitch ?? 0
    }
    
    required public init(cameraPosition: CameraOptions) {
        mapBoxCameraPosition = cameraPosition
    }
    
    func camera(target: CLLocationCoordinate2D, zoom: Float) -> MPCameraPosition? {
        let zoom = zoom - 1
        let cameraOptions = CameraOptions(
            center: target,
            zoom: CGFloat(zoom)
        )
        
        return MBCameraPosition(cameraPosition: cameraOptions)
    }
}

