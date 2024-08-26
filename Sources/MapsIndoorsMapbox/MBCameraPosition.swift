import Foundation
import MapboxMaps
import MapsIndoorsCore

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

    public required init(cameraPosition: CameraOptions) {
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
