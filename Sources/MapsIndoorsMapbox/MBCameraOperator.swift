import Foundation
import MapboxMaps
import MapsIndoorsCore

@MainActor
class MBCameraOperator: MPCameraOperator {
    /// SAFETY: written only by the initialisers, before the operator is handed out, and read only on the main
    /// actor afterwards. `nonisolated(unsafe)` because a weak property starts as `nil`, so the non-isolated
    /// initialiser's first write counts as a mutation of main-actor state rather than an initialisation.
    nonisolated(unsafe) weak var view: MapView?
    nonisolated(unsafe) weak var mapProvider: MPMapProvider?

    /// Read through the view rather than stored, so the initialiser never touches main-actor state.
    var map: MapboxMap? { view?.mapboxMap }

    /// Non-isolated, and it only stores references, so the provider's `cameraOperator` getter can build one on
    /// any thread without a hop. That matters: the view model producer reads `cameraOperator.projection` off the
    /// main actor on every clustered render.
    nonisolated required init(mapView: MapView, provider: MPMapProvider) {
        view = mapView
        mapProvider = provider
    }

    nonisolated init() {}

    func move(target: CLLocationCoordinate2D, zoom: Float) {
        view?.mapboxMap.setCamera(to: CameraOptions(
            center: target,
            padding: mapProvider?.padding,
            zoom: CGFloat(zoom)))
    }

    func animate(pos: MPCameraPosition) async {
        let newCamera = CameraOptions(
            center: CLLocationCoordinate2D(latitude: pos.target.latitude, longitude: pos.target.longitude),
            padding: mapProvider?.padding,
            zoom: CGFloat(pos.zoom),
            bearing: pos.bearing,
            pitch: pos.viewingAngle)
        await withCheckedContinuation { continuation in
            self.view?.camera.ease(to: newCamera, duration: 0.3) { _ in
                continuation.resume()
            }
        }
    }

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
                padding: mapProvider?.padding,
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
