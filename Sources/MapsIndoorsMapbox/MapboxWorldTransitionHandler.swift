import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore

/// Test seam over the subset of `MapboxMap` this handler actually exercises.
/// Tests inject a recording fake to assert per-flag writes without standing up
/// a real Mapbox style.
protocol MBStyleImportConfigSetting: AnyObject {
    func setStyleImportConfigProperty(for importId: String, config: String, value: Any) throws
}

extension MapboxMap: MBStyleImportConfigSetting {}

@MainActor
class MapboxWorldTransitionHandler {
    private let baseMap = "basemap"
    private let placeLabels = "showPlaceLabels"
    private let transitLabels = "showTransitLabels"
    private let roadLabels = "showRoadLabels"
    private let poiLabels = "showPointOfInterestLabels"
    // Mapbox Standard's fill-extrusion building opacity (0.0–1.0). A float, so it fades
    // buildings gradually across the transition band — the "full" online experience.
    private let buildingOpacity = "buildingsOpacity"
    // Mapbox Standard's binary umbrella toggle for all 3D objects (buildings + landmark models
    // + trees). Used as the offline fallback (see `useShow3dObjectsNow`).
    private let show3dObjects = "show3dObjects"

    // How base-map buildings are hidden across the transition band:
    //  - buildingsOpacity: graded float → gradual fade. The live Standard style honours this
    //    key online.
    //  - show3dObjects: binary umbrella toggle → hard hide, the offline fallback (the cached
    //    Standard style does not honour buildingsOpacity offline).
    //  - auto (default): buildingsOpacity when online, show3dObjects when offline — full
    //    experience online, graceful degradation offline.
    enum BuildingHideMode: Int { case auto = 0, buildingsOpacity = 1, show3dObjects = 2 }

    // Optional override, read live from UserDefaults. Absent/0 → auto. Primarily a test/QA seam;
    // observers re-apply on `buildingHideModeChanged` so a change takes effect immediately.
    static let buildingHideModeDefaultsKey = "pp.debug.buildingHideMode"
    static let buildingHideModeChanged = Notification.Name("pp.debug.buildingHideModeChanged")

    /// Whether to hide buildings via the binary `show3dObjects` right now — honours the override,
    /// and in `auto` falls back to `show3dObjects` only when offline.
    private var useShow3dObjectsNow: Bool {
        switch BuildingHideMode(rawValue: UserDefaults.standard.integer(forKey: Self.buildingHideModeDefaultsKey)) ?? .auto {
        case .buildingsOpacity: return false
        case .show3dObjects: return true
        case .auto: return !NetworkPathMonitor.shared.isConnected
        }
    }

    private var reapplyObservers: [NSObjectProtocol] = []

    weak var map: MapBoxProvider?
    var enableMapboxBuildings = true {
        didSet {
            // Reset cached state so the next call applies the change
            lastAppliedWorldState = nil
            lastAppliedMarkerConfig = nil
            Task { [weak self] in
                await self?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
    }

    nonisolated required init(mapProvider: MapBoxProvider) {
        map = mapProvider
        // Re-apply immediately when connectivity changes (auto mode flips buildingsOpacity <->
        // show3dObjects) or when the building-hide override changes — so the switch is visible
        // without having to cross the transition band again.
        for name in [NetworkPathMonitor.networkStatusChanged, Self.buildingHideModeChanged] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.reapplyVisibility() }
            }
            reapplyObservers.append(token)
        }
    }

    deinit {
        reapplyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Apply the base-map building visibility for the given target opacity.
    ///
    /// Writes BOTH import-config keys on every apply — the active mechanism plus the other key reset
    /// to its neutral (non-suppressing) value. The two keys are independent, and only a style reload
    /// resets import config to defaults, so writing just one would let the other stay latched: an
    /// offline `show3dObjects = false` would keep all base-map 3D content hidden after reconnecting
    /// (when we switch to `buildingsOpacity`) until the next style reload. Re-applying both — driven
    /// by the `reapplyVisibility()` on a connectivity/mode change — guarantees a mechanism switch
    /// takes effect immediately.
    ///
    /// - `useShow3dObjectsNow` (offline, or forced): drive the binary umbrella `show3dObjects`
    ///   (opacity ≥ 1.0 → shown, otherwise hidden) and neutralise the graded key to fully-opaque.
    /// - otherwise (online): drive the graded `buildingsOpacity` fade and neutralise the umbrella to
    ///   shown (`true`), so a prior offline hard-hide can't linger.
    private func applyBuildingConfig(opacity: Double, on map: MBStyleImportConfigSetting) throws {
        if useShow3dObjectsNow {
            try map.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: 1.0)
            try map.setStyleImportConfigProperty(for: baseMap, config: show3dObjects, value: opacity >= 1.0)
        } else {
            try map.setStyleImportConfigProperty(for: baseMap, config: show3dObjects, value: true)
            try map.setStyleImportConfigProperty(for: baseMap, config: buildingOpacity, value: opacity)
        }
    }

    /// Tracks the last applied world state to avoid redundant style config calls
    private enum WorldState: Equatable { case mapsindoors, mapbox, intermediary }
    private var lastAppliedWorldState: WorldState?
    /// Tracks the last applied marker/road label config to avoid redundant calls
    private var lastAppliedMarkerConfig: (showMarkers: Bool?, showRoads: Bool?)?

    /// Test injection point — when non-nil, all style-import writes route here
    /// instead of the live `MapboxMap`. Internal so `@testable import` tests can
    /// assert the exact writes per flag combination.
    internal var mapboxMapOverride: MBStyleImportConfigSetting?

    private var activeMapboxMap: MBStyleImportConfigSetting? {
        mapboxMapOverride ?? map?.mapView?.mapboxMap
    }

    /// Force a fresh application of the world / marker visibility, discarding the
    /// applied-state caches first, then re-apply against the current camera.
    ///
    /// Needed whenever the previously applied config can no longer be trusted:
    /// a style (re)load resets every style-import config back to its defaults,
    /// and a transition-level change must take effect immediately. In both cases
    /// the `lastApplied*` caches would otherwise short-circuit the re-apply. This
    /// runs independently of camera movement, so the configured transition level
    /// is honoured even when the map opens already zoomed past it (SPEX-2097).
    func reapplyVisibility() async {
        lastAppliedWorldState = nil
        lastAppliedMarkerConfig = nil
        await configureMapsIndoorsVsMapboxVisibility()
    }

    /// Overridable so tests can subclass via `@testable import` and count invocations
    /// scheduled by `MapBoxProvider` property didSet observers.
    func configureMapsIndoorsVsMapboxVisibility() async {
        guard let map, let activeMapboxMap else { return }

        do {
            // Only apply marker/label config when it actually changes
            let currentMarkerConfig = (showMarkers: map.showMapboxMapMarkers, showRoads: map.showMapboxRoadLabels)
            let markerConfigChanged =
                lastAppliedMarkerConfig == nil
                || lastAppliedMarkerConfig?.showMarkers != currentMarkerConfig.showMarkers
                || lastAppliedMarkerConfig?.showRoads != currentMarkerConfig.showRoads

            if markerConfigChanged {
                if map.showMapboxMapMarkers == true {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
                } else {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
                }
                if map.showMapboxRoadLabels == true {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
                } else {
                    try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
                }
                lastAppliedMarkerConfig = currentMarkerConfig
            }

            let currentZoom = Double(map.cameraOperator.position.zoom - 1)
            let transition = Double(map.transitionLevel)

            let newWorldState: WorldState
            if currentZoom > transition + 1 {
                newWorldState = .mapsindoors
            } else if currentZoom < transition {
                newWorldState = .mapbox
            } else {
                newWorldState = .intermediary
            }

            // Skip redundant style updates when world state hasn't changed
            if newWorldState != lastAppliedWorldState {
                switch newWorldState {
                case .mapsindoors:
                    try applyShowMapsIndoorsWorld()
                case .mapbox:
                    try applyShowMapboxWorld()
                case .intermediary:
                    try applyShowIntermediaryWorld()
                }
                // Cache the applied state only after the writes succeed. If a
                // write throws — e.g. the style is still settling right after
                // load and cannot yet accept import config — the state stays
                // uncached so the next call retries instead of wrongly treating
                // it as applied (SPEX-2097).
                lastAppliedWorldState = newWorldState
            }

            if enableMapboxBuildings == false {
                try applyBuildingConfig(opacity: 0.0, on: activeMapboxMap)
            }
        } catch {
            MPLog.mapbox.info("Failed to configure style config properties.")
        }
    }

    /// Hide all Mapbox content which interfering with MapsIndoors content
    private func applyShowMapsIndoorsWorld() throws {
        guard let map, let activeMapboxMap else { return }

        try applyBuildingConfig(opacity: 0.0, on: activeMapboxMap)

        if map.showMapboxMapMarkers == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
        }

        if map.showMapboxRoadLabels == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
        }
    }

    private func applyShowIntermediaryWorld() throws {
        guard let activeMapboxMap else { return }
        // Half-fade the base-map buildings in the transition band so they blend out gradually
        // on the way into the MapsIndoors world (rather than snapping off).
        try applyBuildingConfig(opacity: 0.5, on: activeMapboxMap)
    }

    /// Show all Mapbox content, if enabled
    private func applyShowMapboxWorld() throws {
        guard let map, let activeMapboxMap else { return }

        try applyBuildingConfig(opacity: enableMapboxBuildings ? 1.0 : 0.0, on: activeMapboxMap)

        if map.showMapboxMapMarkers == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: true)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: placeLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: poiLabels, value: false)
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: transitLabels, value: false)
        }

        if map.showMapboxRoadLabels == true {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: true)
        } else {
            try activeMapboxMap.setStyleImportConfigProperty(for: baseMap, config: roadLabels, value: false)
        }
    }
}
