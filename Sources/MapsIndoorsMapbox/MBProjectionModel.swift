import Foundation
import MapsIndoorsCore
import MapboxMaps

class MBProjectionModel: MPProjection {
    
    private weak var view: MapView?
    
    required init(view: MapView?) {
        self.view = view
    }
    
    init() { }
    
    var visibleRegion: MPGeoRegion {
        @MainActor
        get {
            guard let view else { return MPGeoRegion(nearLeft: CLLocationCoordinate2D(), farLeft: CLLocationCoordinate2D(), farRight: CLLocationCoordinate2D(), nearRight: CLLocationCoordinate2D()) }
            
            // Using the view's frame, we can derive latlngs for each corner of the camera view
            let farLeft = view.mapboxMap.coordinate(for:    CGPoint(x: 0,                   y: 0))
            let farRight = view.mapboxMap.coordinate(for:   CGPoint(x: view.frame.width,    y: 0))
            let nearLeft = view.mapboxMap.coordinate(for:   CGPoint(x: 0,                   y: view.frame.height))
            let nearRight = view.mapboxMap.coordinate(for:  CGPoint(x: view.frame.width,    y: view.frame.height))
            let center = view.mapboxMap.coordinate(for:     CGPoint(x: view.frame.width/2,  y: view.frame.height/2))

            // Add a 50% buffer to the viewport area
            
            let nearLeftBearingToCenter = MPGeometryUtils.bearingBetweenPoints(from: nearLeft, to: center) + 180
            let nearLeftDistanceToCenter = MPGeometryUtils.distance(from: MPGeoPoint(coordinate: nearLeft), to: MPGeoPoint(coordinate: center))
            let nearLeftOffset = MPGeometryUtils.computeOffset(from: nearLeft, dist: nearLeftDistanceToCenter, head: nearLeftBearingToCenter)
            
            let nearRightBearingToCenter = MPGeometryUtils.bearingBetweenPoints(from: nearRight, to: center) + 180
            let nearRighDistanceToCenter = MPGeometryUtils.distance(from: MPGeoPoint(coordinate: nearRight), to: MPGeoPoint(coordinate: center))
            let nearRighOffset = MPGeometryUtils.computeOffset(from: nearRight, dist: nearRighDistanceToCenter, head: nearRightBearingToCenter)
            
            let farLeftBearingToCenter = MPGeometryUtils.bearingBetweenPoints(from: farLeft, to: center) + 180
            let farLeftDistanceToCenter = MPGeometryUtils.distance(from: MPGeoPoint(coordinate: farLeft), to: MPGeoPoint(coordinate: center))
            let farLeftOffset = MPGeometryUtils.computeOffset(from: farLeft, dist: farLeftDistanceToCenter, head: farLeftBearingToCenter)
            
            let farRightBearingToCenter = MPGeometryUtils.bearingBetweenPoints(from: farRight, to: center) + 180
            let farRightDistanceToCenter = MPGeometryUtils.distance(from: MPGeoPoint(coordinate: farRight), to: MPGeoPoint(coordinate: center))
            let farRightOffset = MPGeometryUtils.computeOffset(from: farRight, dist: farRightDistanceToCenter, head: farRightBearingToCenter)
            
            let bufferedRegion = MPGeoRegion(nearLeft: nearLeftOffset,
                                             farLeft: farLeftOffset,
                                             farRight: farRightOffset,
                                             nearRight: nearRighOffset
            )
            
            return bufferedRegion
        }
    }

    @MainActor
    func coordinateFor(point: CGPoint) async -> CLLocationCoordinate2D {
        return view?.mapboxMap.coordinate(for: point) ?? CLLocationCoordinate2D()
    }
    
    @MainActor
    func pointFor(coordinate: CLLocationCoordinate2D) async -> CGPoint {
        return view?.mapboxMap.point(for: coordinate) ?? CGPointZero
    }

}
