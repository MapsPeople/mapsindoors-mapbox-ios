import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoorsCore

/// Test seam over the subset of `MapboxMap` this handler actually exercises.
/// Tests inject a recording fake to assert per-flag writes without standing up
/// a real Mapbox style.
protocol MBStyleImportConfigSetting: AnyObject {
    func setStyleImportConfigProperty(for importId: String, config: String, value: Any) throws
    /// The current value of an import config: a colour string, an expression array, a number, ….
    func styleImportConfigValue(for importId: String, config: String) throws -> Any
}

extension MapboxMap: MBStyleImportConfigSetting {
    func styleImportConfigValue(for importId: String, config: String) throws -> Any {
        try getStyleImportConfigProperty(for: importId, config: config).value
    }
}

@MainActor
class MapboxWorldTransitionHandler {
    private let baseMap = "basemap"
    private let placeLabels = "showPlaceLabels"
    private let transitLabels = "showTransitLabels"
    private let roadLabels = "showRoadLabels"
    private let poiLabels = "showPointOfInterestLabels"
    /// Mapbox Standard's building colour config ("Set a custom color for 3D & 2D buildings"). The sole
    /// mechanism for fading base-map buildings across the transition band (SPEX-2517): Standard derives
    /// building opacity from its alpha, online and offline alike. It replaces `buildingsOpacity`, which
    /// existed only in an experimental basemap and had no effect offline, and the `show3dObjects`
    /// fallback, which also hid landmark models and trees.
    private let colorBuildings = "colorBuildings"

    /// The style's own `colorBuildings`, read before the first write after each style load. The fade
    /// writes this colour back with only its alpha scaled, so a building colour set by a host style
    /// survives. `raw` is the value as read, written back verbatim at full opacity when it could not
    /// be parsed, so an unparseable host colour is still restored.
    private struct BuildingColorBaseline {
        let color: MBBuildingColor
        let raw: Any
        let parsed: Bool
    }

    /// Cleared by ``resetBuildingColorBaseline()`` when a new style's JSON loads — the point at which
    /// Mapbox resets import config.
    private var buildingColorBaseline: BuildingColorBaseline?

    /// The last colour written, and the baseline alpha it was scaled from. A write that lands after
    /// the reset but before the baseline is read would otherwise be adopted as the style's own colour,
    /// and an adopted alpha of 0 would keep the buildings hidden until the next style load.
    private var lastBuildingWrite: (color: MBBuildingColor, baselineAlpha: Double)?

    /// The opacity last written, so repeated applies at the same opacity (the camera-driven
    /// `enableMapboxBuildings == false` path) do not rewrite the config. Cleared whenever the written
    /// value can no longer be trusted.
    private var lastAppliedBuildingOpacity: Double?

    /// A style that rejects `colorBuildings`, or reports a colour that cannot be parsed, fails every
    /// apply; log that once, not per camera change.
    private var didLogBuildingFadeFailure = false

    weak var map: MapBoxProvider?
    var enableMapboxBuildings = true {
        didSet {
            // Reset cached state so the next call applies the change
            lastAppliedWorldState = nil
            lastAppliedMarkerConfig = nil
            lastAppliedBuildingOpacity = nil
            Task { [weak self] in
                await self?.configureMapsIndoorsVsMapboxVisibility()
            }
        }
    }

    nonisolated required init(mapProvider: MapBoxProvider) {
        map = mapProvider
    }

    /// Forget the captured building colour. Call synchronously when a new style's JSON has loaded
    /// (`onStyleDataLoaded`, `.style`), which is when Mapbox resets import config: earlier and the
    /// old style's colour is captured, later and a write in between can be read back as the style's.
    func resetBuildingColorBaseline() {
        buildingColorBaseline = nil
        lastAppliedBuildingOpacity = nil
    }

    /// The building colour to fade: the style's own, captured on first use after a style load.
    private func baselineBuildingColor(on map: MBStyleImportConfigSetting) throws -> BuildingColorBaseline {
        if let buildingColorBaseline { return buildingColorBaseline }
        let value = try map.styleImportConfigValue(for: baseMap, config: colorBuildings)
        let baseline: BuildingColorBaseline
        if let parsed = MBBuildingColor(styleValue: value) {
            if let last = lastBuildingWrite, parsed.isApproximatelyEqual(to: last.color) {
                // Our own write, read back: restore the alpha it was scaled from.
                baseline = BuildingColorBaseline(color: parsed.withAlpha(last.baselineAlpha), raw: value, parsed: true)
            } else {
                baseline = BuildingColorBaseline(color: parsed, raw: value, parsed: true)
            }
        } else {
            logBuildingFadeFailureOnce("cannot parse '\(colorBuildings)' value \(value); fading Standard's default colour")
            baseline = BuildingColorBaseline(color: .standardDefault, raw: value, parsed: false)
        }
        buildingColorBaseline = baseline
        return baseline
    }

    /// Apply the base-map building visibility for the given target opacity: write the style's own
    /// building colour back with its alpha scaled by `opacity`. 1.0 restores the style's colour exactly;
    /// 0.0 makes the buildings fully transparent. Hue, saturation and lightness are never changed.
    ///
    /// Not gated on the `basemap` import's reported config keys: when Standard is the root style they
    /// do not describe this key, so gating on them silently kills the fade. A failed read or write is
    /// rethrown so the world state is not cached as applied and the next apply retries (SPEX-2097).
    /// Callers write it after the label configs, so a failure cannot block those.
    private func applyBuildingConfig(opacity: Double, on map: MBStyleImportConfigSetting) throws {
        guard opacity != lastAppliedBuildingOpacity else { return }
        do {
            let baseline = try baselineBuildingColor(on: map)
            let color = baseline.color.withAlpha(baseline.color.alpha * opacity)
            // An unparseable colour is only replaced while fading; at full opacity it goes back as read.
            let value: Any = !baseline.parsed && opacity >= 1 ? baseline.raw : color.styleString(alpha: color.alpha)
            try map.setStyleImportConfigProperty(for: baseMap, config: colorBuildings, value: value)
            lastBuildingWrite = (color, baseline.color.alpha)
            lastAppliedBuildingOpacity = opacity
        } catch {
            logBuildingFadeFailureOnce("'\(colorBuildings)' rejected by the '\(baseMap)' import: \(error)")
            throw error
        }
    }

    private func logBuildingFadeFailureOnce(_ message: String) {
        guard !didLogBuildingFadeFailure else { return }
        didLogBuildingFadeFailure = true
        MPLog.mapbox.error("Base-map building fade: \(message)")
    }

    /// Tracks the last applied world state to avoid redundant style config calls
    private enum WorldState: Equatable { case mapsindoors, mapbox, intermediary }

    /// The base-map building opacity each world state stands for — the single visible consequence of the
    /// state, and so what it is checked by.
    private func buildingOpacity(for state: WorldState) -> Double {
        switch state {
        case .mapsindoors: 0.0
        // Matches `.mapbox` below: with the base map's buildings switched off there is nothing to
        // half-fade, and the pass ends by writing 0.0 regardless. Expecting 0.5 here meant the cache
        // check never matched in the transition band, so the import config was rewritten on every
        // debounced camera change.
        case .intermediary: enableMapboxBuildings ? 0.5 : 0.0
        case .mapbox: enableMapboxBuildings ? 1.0 : 0.0
        }
    }

    /// Whether the map still holds the building fade this state stands for.
    ///
    /// `false` when that cannot be confirmed: the value cannot be read, which covers the window where the
    /// `basemap` import does not exist yet, or no baseline has been read since the last style load.
    /// Writing again then is harmless, and not writing is the bug. Only the alpha is compared, since the
    /// fade changes nothing else and a map that dropped the write holds the style's own colour.
    private func buildingConfigIsApplied(_ state: WorldState) -> Bool {
        guard let activeMapboxMap, let baseline = buildingColorBaseline,
            let value = try? activeMapboxMap.styleImportConfigValue(for: baseMap, config: colorBuildings)
        else { return false }
        let opacity = buildingOpacity(for: state)
        guard let held = MBBuildingColor(styleValue: value) else {
            // An unparseable style colour is written back as read at full opacity, and only there.
            return !baseline.parsed && opacity >= 1
        }
        return abs(held.alpha - baseline.color.alpha * opacity) < 0.01
    }
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
        lastAppliedBuildingOpacity = nil
        await configureMapsIndoorsVsMapboxVisibility()
    }

    /// Overridable so tests can subclass via `@testable import` and count invocations
    /// scheduled by the `MapBoxProvider` property setters.
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

            // The cache records what was written, not what the map kept. A style import that becomes
            // available *after* a successful write comes up with its own default config and silently
            // discards ours — the map is then left with solid buildings covering the MapsIndoors POIs,
            // and every later pass computes the same state and skips the one write that would fix it.
            // Measured on a reproducing cold start: opacity 0.5 applied at 0.48 s, then a pass at 4.89 s
            // skipped as "unchanged" against a map that had reverted to solid.
            let cacheMatchesMap = lastAppliedWorldState.map(buildingConfigIsApplied) ?? false
            if newWorldState != lastAppliedWorldState || cacheMatchesMap == false {
                // The building write keeps its own cache of the last opacity, which would skip the very
                // write this pass is here to repeat.
                if cacheMatchesMap == false { lastAppliedBuildingOpacity = nil }
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

        try applyBuildingConfig(opacity: 0.0, on: activeMapboxMap)
    }

    private func applyShowIntermediaryWorld() throws {
        guard let activeMapboxMap else { return }
        // Half-fade the base-map buildings in the transition band so they blend out gradually
        // on the way into the MapsIndoors world (rather than snapping off) — but only when there are
        // buildings to fade. Through `buildingOpacity(for:)` rather than a literal, so what this writes
        // and what the cache check expects cannot drift apart.
        try applyBuildingConfig(opacity: buildingOpacity(for: .intermediary), on: activeMapboxMap)
    }

    /// Show all Mapbox content, if enabled
    private func applyShowMapboxWorld() throws {
        guard let map, let activeMapboxMap else { return }

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

        try applyBuildingConfig(opacity: enableMapboxBuildings ? 1.0 : 0.0, on: activeMapboxMap)
    }
}
