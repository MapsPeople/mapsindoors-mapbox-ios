import Foundation
import MapboxMaps
import MapsIndoorsCore

class MBCameraOperator: MPCameraOperator {
    weak var map: MapboxMap?
    weak var view: MapView?
    weak var mapProvider: MPMapProvider?

    required init(mapView: MapView, provider: MPMapProvider) {
        map = mapView.mapboxMap
        view = mapView
        mapProvider = provider
    }

    init() {}

    func move(target: CLLocationCoordinate2D, zoom: Float) {
        view?.mapboxMap.setCamera(to: CameraOptions(center: target, zoom: CGFloat(zoom)))
    }

    @MainActor
    func animate(pos: MPCameraPosition) async {
        let newCamera = CameraOptions(
            center: CLLocationCoordinate2D(latitude: pos.target.latitude, longitude: pos.target.longitude),
            zoom: CGFloat(pos.zoom),
            bearing: pos.bearing,
            pitch: pos.viewingAngle)
        await withCheckedContinuation { continuation in
            self.view?.camera.ease(to: newCamera, duration: 0.3) { _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    func animate(bounds: MPGeoBounds) async {
        do {
            if let newCamera = try view?.mapboxMap.camera(for: [bounds.southWest, bounds.northEast], camera: CameraOptions(), coordinatesPadding: mapProvider?.padding, maxZoom: nil, offset: nil) {
                await withCheckedContinuation { continuation in
                    view?.camera.ease(to: newCamera, duration: 0.3) { _ in
                        continuation.resume()
                    }
                }
            }
        } catch {
            MPLog.mapbox.error("Error trying to animate mapbox camera to bounds!")
        }
    }

    @MainActor
    func animate(target: CLLocationCoordinate2D, zoom: Float?) async {
        let curZoom: Float? =
            if let z = self.view?.mapboxMap.cameraState.zoom {
                Float(z)
            } else {
                nil
            }
        if let zoom = zoom ?? curZoom {
            let newCamera = CameraOptions(
                center: target,
                zoom: CGFloat(zoom))
            await withCheckedContinuation { continuation in
                self.view?.camera.ease(to: newCamera, duration: 0.3) { _ in
                    continuation.resume()
                }
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
            MBProjectionModel(view: view)
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
