import Foundation
import MapboxMaps
import MapsIndoorsCore

@MainActor
class MBProjectionModel: MPProjection {
    private weak var view: MapView?

    required init(view: MapView?) {
        self.view = view
    }

    var visibleRegion: MPGeoRegion {
        get async {
            guard let view else { return MPGeoRegion(nearLeft: CLLocationCoordinate2D(), farLeft: CLLocationCoordinate2D(), farRight: CLLocationCoordinate2D(), nearRight: CLLocationCoordinate2D()) }

            // Using the view's frame, we can derive latlngs for each corner of the camera view
            let farLeft = view.mapboxMap.coordinate(for: CGPoint(x: 0, y: 0))
            let farRight = view.mapboxMap.coordinate(for: CGPoint(x: view.frame.width, y: 0))
            let nearLeft = view.mapboxMap.coordinate(for: CGPoint(x: 0, y: view.frame.height))
            let nearRight = view.mapboxMap.coordinate(for: CGPoint(x: view.frame.width, y: view.frame.height))
            let center = view.mapboxMap.coordinate(for: CGPoint(x: view.frame.width / 2, y: view.frame.height / 2))

            // Determine the buffer factor based on the current zoom level
            // This is a heuristic to improve the percieved performance of the map by adding a buffer to the viewport area,
            // pre-rendering areas outside the viewport. A user is less likely to notice "pop-in" while panning/zooming.
            // Obviously this is costly, the larger the buffer becomes - so we gradually increase the buffer size based on the zoom level.
            let zoom = view.mapboxMap.cameraState.zoom
            let bufferFactor =
                switch zoom {
                case 0..<18: 1.0  // Add no buffer to the viewport area
                case 18..<21: 1.25  // Add a 25% buffer to the viewport area
                case 21..<25: 1.5  // Add a 50% buffer to the viewport area
                default: 1.0
                }

            // Each corner moves out along the line from the centre, to `bufferFactor` times its offset from it. Measured
            // from the corner, as before, the corner's own distance came on top and every band was one view too big
            // (SPEX-3132). The offset is scaled in degrees, not through `MPGeometryUtils.distance` and `computeOffset`:
            // those use different earth radii, so a factor of 1 came back 0.1% inside the view. Over a view at the
            // zooms that buffer (18 and up) degrees are as good as metres.
            func buffered(_ corner: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
                var dLng = corner.longitude - center.longitude
                if dLng > 180 { dLng -= 360 } else if dLng < -180 { dLng += 360 }
                var longitude = center.longitude + dLng * bufferFactor
                if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
                return CLLocationCoordinate2D(
                    latitude: center.latitude + (corner.latitude - center.latitude) * bufferFactor, longitude: longitude)
            }
            let nearLeftOffset = buffered(nearLeft)
            let nearRightOffset = buffered(nearRight)
            let farLeftOffset = buffered(farLeft)
            let farRightOffset = buffered(farRight)

            let bufferedRegion = MPGeoRegion(
                nearLeft: nearLeftOffset,
                farLeft: farLeftOffset,
                farRight: farRightOffset,
                nearRight: nearRightOffset)

            return bufferedRegion
        }
    }

    func coordinateFor(point: CGPoint) async -> CLLocationCoordinate2D {
        view?.mapboxMap.coordinate(for: point) ?? CLLocationCoordinate2D()
    }

    func pointFor(coordinate: CLLocationCoordinate2D) async -> CGPoint {
        view?.mapboxMap.point(for: coordinate) ?? .zero
    }
}
