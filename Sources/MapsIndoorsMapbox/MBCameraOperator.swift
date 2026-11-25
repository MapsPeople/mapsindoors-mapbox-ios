import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore

/// The two camera verbs the operator uses, behind a protocol so a test can see which one a move took: a map view
/// that is not on screen sometimes lands an ease instantly and sometimes not at all, so the camera state cannot
/// tell the eased path from the instant one (SPEX-2060).
@MainActor
protocol MBCameraDriving: AnyObject {
    func setCamera(to camera: CameraOptions)
    func ease(to camera: CameraOptions, completion: @escaping () -> Void)
}

/// The production driver: the map view's own camera.
@MainActor
final class MBMapViewCameraDriver: MBCameraDriving {
    private weak var view: MapView?

    init(view: MapView) {
        self.view = view
    }

    func setCamera(to camera: CameraOptions) {
        view?.mapboxMap.setCamera(to: camera)
    }

    func ease(to camera: CameraOptions, completion: @escaping () -> Void) {
        view?.camera.ease(to: camera, duration: 0.3) { _ in completion() }
    }
}

@MainActor
class MBCameraOperator: MPCameraOperator {
    /// Test injection point for the camera verbs; `nil` drives the map view (SPEX-2060).
    var cameraDriverOverride: (any MBCameraDriving)?

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
        // `zoom` is on the Google / 256px-tile scale, matching `MPCameraPosition.zoom` — which this
        // module already converts the same way in `MBCameraPosition` (the getter adds 1, and
        // `camera(target:zoom:)` subtracts it). Mapbox renders 512px tiles and so sits one level below.
        // Writing the value straight through opened the map a full zoom level too close, and the app's
        // own `goTo` then corrected it — the visible jump a seeded camera exists to prevent.
        view?.mapboxMap.setCamera(
            to: CameraOptions(
                center: target,
                padding: mapProvider?.padding,
                zoom: CGFloat(MBZoom.mapbox(fromMapsIndoors: Double(zoom)))))
    }

    func animate(pos: MPCameraPosition) async {
        let newCamera = CameraOptions(
            center: CLLocationCoordinate2D(latitude: pos.target.latitude, longitude: pos.target.longitude),
            padding: mapProvider?.padding,
            // `pos.zoom` is on the MapsIndoors scale, as in `move(target:zoom:)` (SPEX-3147).
            zoom: CGFloat(MBZoom.mapbox(fromMapsIndoors: Double(pos.zoom))),
            bearing: pos.bearing,
            pitch: pos.viewingAngle)
        await apply(newCamera)
    }

    func move(bounds: MPGeoBounds) {
        guard let view else { return }
        do {
            let camera = try fit(bounds, on: view.mapboxMap)
            view.mapboxMap.setCamera(to: withinLimits(camera))
        } catch {
            MPLog.mapbox.error("Error trying to move the Mapbox camera to bounds")
        }
    }

    func animate(bounds: MPGeoBounds) async {
        do {
            if let map = view?.mapboxMap {
                let newCamera = try fit(bounds, on: map)
                await apply(newCamera)
            }
        } catch {
            MPLog.mapbox.error("Error trying to animate mapbox camera to bounds!")
        }
    }

    func animate(target: CLLocationCoordinate2D, zoom: Float?) async {
        // A given zoom is on the MapsIndoors scale and is converted, as in `move(target:zoom:)`. Without one the
        // map keeps its own zoom, which is already on the Mapbox scale (SPEX-3147). Without a map view there is
        // no zoom to keep, so the move is dropped.
        let mapboxZoom: CGFloat? =
            if let zoom {
                CGFloat(MBZoom.mapbox(fromMapsIndoors: Double(zoom)))
            } else {
                view?.mapboxMap.cameraState.zoom
            }
        guard let mapboxZoom else { return }
        let newCamera = CameraOptions(
            center: target,
            padding: mapProvider?.padding,
            zoom: mapboxZoom)
        await apply(newCamera)
    }

    /// The camera a fit to bounds is worked out for: at `MPMapControl.cameraLimits`' fixed bearing and tilt
    /// when they set them. The fit's zoom depends on the bearing the area is seen from, so fitting at
    /// another bearing and then turning to the fixed one leaves the area too big or too small for the
    /// screen. The camera bounds hold a fixed tilt as their pitch range, so their maximum is the steepest
    /// pitch to fit for.
    private var fitCamera: CameraOptions {
        guard let limits = mapProvider?.cameraLimits else { return CameraOptions() }
        let maxPitch = Double(view?.mapboxMap.cameraBounds.maxPitch ?? 0)
        return CameraOptions(
            bearing: limits.fixedBearingDegrees,
            pitch: limits.fixedTiltDegrees(maxTilt: maxPitch).map { CGFloat($0) })
    }

    /// `bounds` fitted inside the provider's padding, at the fixed bearing and tilt of `fitCamera`.
    private func fit(_ bounds: MPGeoBounds, on map: MapboxMap) throws -> CameraOptions {
        let camera = fitCamera
        return try map.camera(
            fitting: [bounds.southWest, bounds.northEast], padding: mapProvider?.padding ?? .zero,
            bearing: camera.bearing, pitch: camera.pitch)
    }

    /// `camera` with its bearing held at `MPMapControl.cameraLimits`' fixed bearing, when it sets one. The
    /// camera bounds already keep zoom, target and pitch inside the limits for a move made in code, but
    /// Mapbox has no bearing bound, so without this the move would turn the map and the idle correction
    /// would then turn it back.
    private func withinLimits(_ camera: CameraOptions) -> CameraOptions {
        guard camera.bearing != nil, let bearing = mapProvider?.cameraLimits?.fixedBearingDegrees else { return camera }
        var kept = camera
        kept.bearing = bearing
        return kept
    }

    /// Eases to `camera` and returns when the ease has finished, or, when motion is not allowed for this map
    /// (host flag or Reduce Motion, see `MPCameraMotion`), sets it in place and returns at once (SPEX-2060).
    /// The instant path goes through `setCamera` rather than a zero-duration ease, so the camera is already
    /// there when the caller resumes and no animator is started at all.
    private func apply(_ camera: CameraOptions) async {
        let camera = withinLimits(camera)
        guard let driver = cameraDriverOverride ?? view.map(MBMapViewCameraDriver.init(view:)) else { return }
        guard MPCameraMotion.shouldAnimate(for: mapProvider) else {
            driver.setCamera(to: camera)
            return
        }
        await withCheckedContinuation { continuation in
            driver.ease(to: camera) {
                continuation.resume()
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
            // Worked out for the provider's padding, which every operator move puts on the camera, so the position
            // still fits once it is applied; `inserts` come on top, as with Google's `camera(for:insets:)`. A nil
            // padding would use whatever padding the camera has now instead (SPEX-3129).
            let mbCameraForBounds = try view?.mapboxMap.camera(
                for: [bounds.southWest, bounds.northEast], camera: CameraOptions(padding: mapProvider?.padding ?? .zero),
                coordinatesPadding: inserts, maxZoom: nil, offset: nil)

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
