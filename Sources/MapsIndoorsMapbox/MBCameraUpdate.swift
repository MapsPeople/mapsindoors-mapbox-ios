//
//  MBCameraUpdate.swift
//  MapsIndoorsMapbox
//
//  Created by Malte Myhlendorph on 20/07/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapsIndoorsCore
import MapboxMaps

class MBCameraUpdate: MPCameraUpdate {
    
    private var camUpdate: CameraOptions
    
    public init(camUpdate: CameraOptions) {
        self.camUpdate = camUpdate
    }
    
    func fitBounds(_ bounds: MPGeoBounds) -> MPCameraUpdate {
        
        let camBounds = CoordinateBounds(southwest: bounds.southWest,
                                         northeast: bounds.northEast)
        
        let newCamera = CameraOptions(center: camBounds.center)
        return MBCameraUpdate(camUpdate: newCamera)
    }
    
    func fitBoundsWithPadding(_ bounds: MPGeoBounds, padding: CGFloat) -> MPCameraUpdate {
        let camBounds = CoordinateBounds(southwest: bounds.southWest,
                                         northeast: bounds.northEast)
        let padding = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        let newCamera = CameraOptions(center: camBounds.center, padding: padding)
        return MBCameraUpdate(camUpdate: newCamera)
    }
    
    func fitBoundsWithEdgeInserts(_ bounds: MPGeoBounds, edgeInsets: UIEdgeInsets) -> MPCameraUpdate {
        let camBounds = CoordinateBounds(southwest: bounds.southWest,
                                         northeast: bounds.northEast)
        
        let newCamera = CameraOptions(center: camBounds.center, padding: edgeInsets)
        return MBCameraUpdate(camUpdate: newCamera)
    }
}
