import Foundation
import MapboxMaps
@_spi(Private) import MapsIndoors
import MapsIndoorsCore

extension BinaryFloatingPoint {
    var degrees: Self {
        self * 180.0 / .pi
    }

    var radians: Self {
        self * .pi / 180.0
    }
}

class MBRouteRenderer: MPRouteRenderer {
    private weak var mapView: MapView?
    var routeMarkerDelegate: MPRouteMarkerDelegate?

    private var valueAnimator: RouteLineAnimator?

    /// Keeps the Mapbox map rendering continuously WHILE an animation runs, without moving the camera: each
    /// finished frame requests the next (the idiom a camera fly relies on). A per-frame layer-property write
    /// alone does not reliably wake an idle Mapbox map, so this is what keeps flow / pulse / comet alive across
    /// an in-place, non-camera-moving re-render. Held while animating; cancelled (→ map idles) when it stops.
    private var renderLoopToken: AnyCancelable?
    // Bumped per apply(); a tick from a superseded generation bails so a stale animation frame (already
    // dispatched to main from the previous animator) can't write to the layer after a newer apply() —
    // e.g. an old flow tick re-trimming the line right after a live switch to pulse.
    private var animationGeneration = 0

    private var route = [CLLocationCoordinate2D]()

    private static let casingOffset = 2.0  // default halo padding per side (total width = strokeWeight + 2 × this)
    private static let fallbackColor = UIColor(red: 48.0 / 255.0, green: 113.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
    private static let stampImageID = "ROUTE_STAMP_IMAGE"

    /// Dash array (line-width units; nil = solid) + line cap for a stroke style.
    /// Shared by the base and animated line layers so the two never diverge.
    private static func dashPattern(for style: MPStrokeStyle) -> (pattern: [Double]?, cap: LineCap) {
        switch style {
        case .solid: return (nil, .butt)
        case .dashed: return ([4, 2], .round)
        case .dotted: return ([0, 1.5], .round)
        @unknown default: return (nil, .butt)
        }
    }

    required init(mapView: MapView?) {
        self.mapView = mapView
        configureSources()
        self.mapView?.mapboxMap.addMapsIndoorsLayers()
    }

    func configureSources() {
        guard let mapView else {
            MPLog.mapbox.debug("Error setting up sources in route renderer!")
            return
        }

        if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) == false {
            var lineSource = GeoJSONSource(id: Constants.SourceIDs.lineSource)
            lineSource.data = .geometry(LineString([]).geometry)
            do {
                try mapView.mapboxMap.addSource(lineSource)
            } catch {
                MPLog.mapbox.debug("Error setting up line source in route renderer!")
            }
        }

        if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.animatedLineSource) == false {
            var animatedSource = GeoJSONSource(id: Constants.SourceIDs.animatedLineSource)
            animatedSource.data = .geometry(LineString([]).geometry)
            // lineMetrics enables line-trim-offset: the flow overlay reveals by trimming the
            // full route geometry, so there is no per-frame partial-geometry recompute.
            animatedSource.lineMetrics = true
            do {
                try mapView.mapboxMap.addSource(animatedSource)
            } catch {
                MPLog.mapbox.debug("Error setting up animated line source in route renderer!")
            }
        }

        if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) == false {
            var markerSource = GeoJSONSource(id: Constants.SourceIDs.routeMarkerSource)
            markerSource.data = .featureCollection(FeatureCollection(features: [Feature]()))
            do {
                try mapView.mapboxMap.addSource(markerSource)
            } catch {
                MPLog.mapbox.debug("Error setting up marker source in route renderer!")
            }
        }
    }

    func apply(model: RouteViewModelProducer, options: MPDirectionsRendererOptions, animate: Bool, duration: TimeInterval, pathSmoothing: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyOnMain(model: model, options: options, animate: animate, duration: duration, pathSmoothing: pathSmoothing)
        }
    }

    private func applyOnMain(model: RouteViewModelProducer, options: MPDirectionsRendererOptions, animate: Bool, duration: TimeInterval, pathSmoothing _: Bool) {
        // Cancel any in-flight animator AND stop the continuous-render loop before the style guard, so if this
        // apply bails (style not loaded) neither keeps running against a stale/absent style. The animate branch
        // below re-arms the render loop; a non-animate apply leaves it stopped so the map idles.
        valueAnimator?.invalidate()
        valueAnimator = nil
        stopRenderLoop()
        // Supersede the previous animation: ticks captured under an older generation bail (below).
        animationGeneration += 1
        let generation = animationGeneration
        guard let mapView, mapView.mapboxMap.isStyleLoaded else { return }

        configureSources()

        route = model.polyline

        let strokeColor = options.strokeColor ?? MBRouteRenderer.fallbackColor
        let strokeOpacity = options.strokeOpacity?.doubleValue ?? 1.0
        let strokeWeight = options.strokeWeight?.doubleValue ?? 4.0
        let strokeStyle = options.strokeStyle ?? .solid
        // Halo shows by default (a faint version of the line colour) unless explicitly disabled.
        let haloEnabled = options.backgroundColorEnabled?.boolValue ?? true
        let haloColor = options.backgroundColor ?? strokeColor
        let haloOpacity = options.backgroundColor != nil ? (options.backgroundColorOpacity?.doubleValue ?? 1.0) : 0.3
        let haloWidth = strokeWeight + 2 * (options.backgroundColorWeight?.doubleValue ?? MBRouteRenderer.casingOffset)
        // Elevation (3D): lift every route layer by `elevationHeight` metres when enabled; Mapbox v11 only.
        // Core always resolves a height, so the fallback here only documents the same built-in default.
        let elevated = options.elevated?.boolValue ?? false
        let elevationHeight = options.elevationHeight?.doubleValue ?? 0.3

        // Draw line
        let geom = LineString(route).geometry

        do {
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
                try mapView.mapboxMap.updateLayer(withId: Constants.LayerIDs.routeMarkerLayer, type: SymbolLayer.self) { symbolLayer in
                    symbolLayer.source = Constants.SourceIDs.routeMarkerSource
                    symbolLayer.iconAllowOverlap = .constant(true)
                    symbolLayer.textAllowOverlap = .constant(true)
                    symbolLayer.iconImage = .expression(Exp(.image) { Exp(.id) })
                    symbolLayer.iconAnchor = .expression(Exp(.get) { Key.markerIconPlacement.rawValue })

                    symbolLayer.textField = .expression(Exp(.get) { Key.markerLabel.rawValue })
                    symbolLayer.textAnchor = .expression(Exp(.get) { Key.labelAnchor.rawValue })
                    symbolLayer.textJustify = .constant(TextJustify.center)
                    symbolLayer.textMaxWidth = .constant(99999999.0)
                    symbolLayer.textFont = .constant(["Open Sans Bold", "Arial Unicode MS Regular"])
                    symbolLayer.textLetterSpacing = .constant(-0.01)
                    // Read label style per-feature (matches the main marker layer + Google), so a start/end
                    // display rule's label colour/size/halo is honoured. Colours are hex strings — Mapbox
                    // accepts a `get` string for text-color directly. Every route marker carries these props.
                    symbolLayer.textSize = .expression(Exp(.get) { Key.labelSize.rawValue })
                    symbolLayer.textColor = .expression(Exp(.get) { Key.labelColor.rawValue })
                    symbolLayer.textHaloColor = .expression(Exp(.get) { Key.labelHaloColor.rawValue })
                    symbolLayer.textHaloWidth = .expression(Exp(.get) { Key.labelHaloWidth.rawValue })
                    symbolLayer.textHaloBlur = .expression(Exp(.get) { Key.labelHaloBlur.rawValue })
                }
            }
        } catch {
            MPLog.mapbox.error("Error updating route polyline in route renderer!")
        }

        do {
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
                // Halo / casing — widest, drawn beneath the base line. A nil backgroundColor disables it (opacity 0).
                try mapView.mapboxMap.updateLayer(withId: Constants.LayerIDs.lineLayer, type: LineLayer.self) { lineLayer in
                    // Strip the colour's own alpha so opacity is driven solely by lineOpacity — matches
                    // Google (withAlphaComponent), so a semi-transparent backgroundColor + explicit opacity
                    // renders the same on both providers.
                    lineLayer.lineColor = .constant(StyleColor(haloColor.withAlphaComponent(1.0)))
                    lineLayer.lineOpacity = .constant(haloEnabled ? haloOpacity : 0)
                    lineLayer.lineWidth = .constant(haloWidth)
                    lineLayer.lineCap = .constant(.round)
                    lineLayer.lineJoin = .constant(.round)
                }
                // Static styled base line (strokeColor / opacity / weight / style) — ALWAYS visible.
                // The flow animation is a separate overlay on top; the route line no longer hides
                // while animating.
                try mapView.mapboxMap.updateLayer(withId: Constants.LayerIDs.baseLineLayer, type: LineLayer.self) { baseLayer in
                    let dash = MBRouteRenderer.dashPattern(for: strokeStyle)
                    // Strip the colour's own alpha here too, so opacity comes solely from lineOpacity: keeping
                    // it would multiply the two and render a semi-transparent strokeColor darker on Google
                    // (which folds opacity in with withAlphaComponent) than here.
                    baseLayer.lineColor = .constant(StyleColor(strokeColor.withAlphaComponent(1.0)))
                    baseLayer.lineOpacity = .constant(strokeOpacity)
                    baseLayer.lineWidth = .constant(strokeWeight)
                    baseLayer.lineJoin = .constant(.round)
                    baseLayer.lineDasharray = dash.pattern.map { .constant($0) }
                    baseLayer.lineCap = .constant(dash.cap)
                }
            }
        } catch {
            MPLog.mapbox.error("Error updating route polyline in route renderer!")
        }

        // Repeating stamp (arrow / custom icon) along the line — a static decoration, independent of the
        // travelling animation. Line placement repeats the icon every `symbol-spacing` points, oriented to
        // the line. The value-carrying props are set imperatively (setLayerProperty), not via updateLayer,
        // which skips writing a value equal to the layer default (e.g. icon-size 1 / visibility visible) and
        // would otherwise leave a previous route's stamp settings in place.
        let stampType = options.stampType ?? .none
        let stampImage = RouteStampIcon.image(type: stampType, arrowStyle: options.arrowStyle ?? .chevron, color: options.stampColor ?? .white, customImage: options.stampImage)
        let stampSpacing = options.stampSpacing?.doubleValue ?? 24
        let stampScale = options.stampScale?.doubleValue ?? 1.0
        // Target on-screen icon size. The arrow stays proportional to the line weight (kept in sync with
        // Google); a custom icon renders at a fixed 24 pt @1× base (× scale), so its size doesn't track the line
        // weight or the source image. icon-size scales the source uniformly, so divide by its LONGER side below.
        let stampSize = (stampType == .custom ? 24.0 : strokeWeight * 2.5) * stampScale
        do {
            try mapView.mapboxMap.updateLayer(withId: Constants.LayerIDs.stampLayer, type: SymbolLayer.self) { stampLayer in
                // source is fixed at layer creation (MapboxMap+Extension); it isn't settable via updateLayer in v11.
                stampLayer.symbolPlacement = .constant(.line)
                // Both the arrow and a custom icon follow the line — they rotate to the travel direction through turns.
                stampLayer.iconRotationAlignment = .constant(.map)
                stampLayer.iconAllowOverlap = .constant(true)
                stampLayer.iconIgnorePlacement = .constant(true)
            }
            if let stampImage {
                let iconScale = stampSize / max(Double(max(stampImage.size.width, stampImage.size.height)), 1)
                // try? (not try) so a failed image registration can't skip the layer-property writes below.
                try? mapView.mapboxMap.addImage(stampImage, id: MBRouteRenderer.stampImageID, sdf: false)
                try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "icon-image", value: MBRouteRenderer.stampImageID)
                try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "icon-size", value: iconScale)
                try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "symbol-spacing", value: stampSpacing)
                try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "visibility", value: "visible")
            } else {
                try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "visibility", value: "none")
            }
        } catch {
            MPLog.mapbox.error("Error updating route stamp layer in route renderer!")
        }

        commitMarkers(model: model, on: mapView)

        if animate {
            // The travelling overlay sits ON TOP of the always-visible base line, using its own style
            // (animatedOverlay*, defaulting to the route-line look), solid — the static base line beneath
            // carries any dash/dot. How it moves depends on the type:
            //   flow  — draws the whole route and reveals it progressively via line-trim-offset
            //   pulse — draws the whole route; its opacity oscillates in place
            //   comet — feeds the source a short segment that slides along the route (a moving window)
            // Colour and opacity are kept apart the same way as the base line and the halo: strip the colour's
            // embedded alpha and let line-opacity carry it, so the overlay matches Google. The fallbacks mirror
            // core's resolved defaults (which always populate these, so they are belt-and-braces).
            let overlayColor = (options.animatedOverlayColor ?? strokeColor).withAlphaComponent(1.0)
            let overlayOpacity = options.animatedOverlayOpacity?.doubleValue ?? 1.0
            let overlayWeight = options.animatedOverlayWeight?.doubleValue ?? strokeWeight
            let animationType = options.animationType ?? .flow
            do {
                if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.animatedLineSource) {
                    // All types draw the WHOLE route in the animated source; the motion comes from trimming
                    // (flow reveals [0, progress]; comet paints a moving [tail, head] window), never from feeding
                    // geometry per frame. Trimming is a synchronous style write, so nothing desyncs on an idle
                    // map the way a per-frame async source swap did.
                    mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.animatedLineSource, geoJSON: GeoJSONObject.geometry(geom))
                }
                try mapView.mapboxMap.updateLayer(withId: Constants.LayerIDs.animatedLineLayer, type: LineLayer.self) { lineLayer in
                    // Comet paints ONLY its moving window, via line-trim-color (the trimmed span); its base
                    // line-color is therefore transparent. Flow / pulse paint the whole overlay via line-color.
                    lineLayer.lineColor = .constant(StyleColor(animationType == .comet ? .clear : overlayColor))
                    lineLayer.lineWidth = .constant(overlayWeight)
                    lineLayer.lineJoin = .constant(.round)
                    lineLayer.lineCap = .constant(.round)
                    lineLayer.lineDasharray = nil
                }
                // trim-offset / opacity / trim-color are written per-frame or per-type, so set them imperatively
                // here rather than via updateLayer: a typed value equal to the property's default can be skipped
                // by updateLayer, leaving the previous animation's last frame in place. Flow starts fully trimmed
                // (the animator reveals it); pulse and comet start untrimmed.
                try? mapView.mapboxMap.setLayerProperty(
                    for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-offset",
                    value: animationType == .flow ? [0.0, 1.0] : [0.0, 0.0])
                try? mapView.mapboxMap.setLayerProperty(
                    for: Constants.LayerIDs.animatedLineLayer, property: "line-opacity", value: overlayOpacity)
                // Comet's bright window is the TRIMMED span, so its colour is line-trim-color; flow / pulse must
                // reset trim-color to transparent so their hidden (trimmed) portion doesn't inherit a previous
                // comet's colour on a live type switch.
                let overlayTrimColor = animationType == .comet ? MBRouteRenderer.rgbaString(from: overlayColor) : "rgba(0, 0, 0, 0)"
                try? mapView.mapboxMap.setLayerProperty(
                    for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-color", value: overlayTrimColor)
            } catch {
                MPLog.mapbox.error("Error updating animated route overlay in route renderer!")
            }

            valueAnimator = RouteLineAnimator(
                duration: duration,
                repeatMode: options.animationRepeating ? .infinite : .once,
                onProgress: { [weak self] progress in
                    // On the main thread (CADisplayLink). setLayerProperty writes just the one property —
                    // updateLayer round-trips the whole layer every frame, which stutters. Drop a tick from a
                    // superseded animator (e.g. a live type switch replaced it); otherwise an old flow/comet
                    // tick would re-trim or re-window the layer under the new animation.
                    guard let self, generation == self.animationGeneration,
                        let mapView = self.mapView, mapView.mapboxMap.isStyleLoaded else { return }
                    switch animationType {
                    case .pulse:
                        // Oscillate opacity dim → bright → dim over each loop; never fully vanish.
                        let opacity = overlayOpacity * RouteFlowGeometry.pulseOpacityFactor(progress: progress)
                        try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.animatedLineLayer, property: "line-opacity", value: opacity)
                    case .comet:
                        // A fixed-length bright window slides along the route, painted as the trimmed span over
                        // the transparent full overlay line — a synchronous property write like flow, so there's
                        // no async source swap to desync on an idle map. lineMetrics normalises trim to 0…1.
                        let window = RouteFlowGeometry.cometTrimWindow(progress: progress)
                        try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-offset", value: [window.tail, window.head])
                    default:
                        // flow: grow the revealed portion [0, progress]; [progress, 1] stays transparent.
                        try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-offset", value: [progress, 1.0])
                    }
                    // No triggerRepaint here: the continuous-render loop (started alongside this animator) keeps
                    // the map painting every frame, so writing the property above is enough.
                },
                onEnd: { [weak self] in
                    // Natural (non-repeating) completion only. Bail if superseded (a newer animator owns the
                    // render loop now); otherwise stop the loop FIRST — it needs no style — so it can't leak
                    // when the style is momentarily unloaded at completion, then do the style-gated hide. Flow /
                    // pulse trim everything away ([0,1]); comet (painted via trim-color) collapses its window ([0,0]).
                    guard let self, generation == self.animationGeneration else { return }
                    self.stopRenderLoop()
                    guard let mapView = self.mapView, mapView.mapboxMap.isStyleLoaded else { return }
                    let hideTrim = animationType == .comet ? [0.0, 0.0] : [0.0, 1.0]
                    try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-offset", value: hideTrim)
                    mapView.mapboxMap.triggerRepaint()
                })
            valueAnimator?.start()
            startRenderLoop()
        } else {
            // No travelling animation — stop the continuous-render loop (let the map idle) and keep the overlay
            // hidden so only the static base line shows.
            stopRenderLoop()
            try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.animatedLineLayer, property: "line-trim-offset", value: [0.0, 1.0])
        }

        // Lift / ground the whole route. Runs on every apply, outside the animate branch (so the overlay is
        // elevated too) and unconditionally (so grounding a previously elevated route always resets).
        applyElevation(elevated: elevated, height: elevationHeight, on: mapView)

        // A programmatic re-render on an idle map (e.g. a late icon download, an options toggle) does not
        // repaint on its own — force one so the update shows without needing a camera move.
        mapView.mapboxMap.triggerRepaint()
    }

    /// The elevation layer-property values for the 3D route line: the line and symbol elevation references and
    /// the z-offset written to every route layer. Grounding (`elevated == false`) returns line reference `none`
    /// and z-offset `0`. A negative height is floored to `0` so the line can't sink below the floor plane —
    /// `line-z-offset` has no minimum (unlike `symbol-z-offset`, which floors at 0), so the SDK clamps it here.
    /// Pure, so the mapping (and the clamp) is unit-testable without a map.
    static func elevationLayerValues(elevated: Bool, height: Double) -> (lineReference: String, symbolReference: String, zOffset: Double) {
        (lineReference: elevated ? "ground" : "none", symbolReference: "ground", zOffset: elevated ? max(height, 0) : 0)
    }

    /// Lifts (or grounds) every route layer for the 3D-elevated-line option — Mapbox v11 only. Written with the
    /// imperative string `setLayerProperty` API rather than the typed `updateLayer` accessors because grounding a
    /// previously-elevated route writes the layer DEFAULT values (line-z-offset `0`, line-elevation-reference
    /// `none`), which `updateLayer` skips — leaving the route stuck elevated; the imperative write always lands.
    /// (The symbol z-offset / elevation-reference accessors are additionally `@_spi(Experimental)` in this SDK;
    /// the line accessors are stable public API, but the grounding-reset reason applies to all five layers.)
    /// `try?` mirrors the surrounding stamp / trim writes.
    private func applyElevation(elevated: Bool, height: Double, on mapView: MapView) {
        let values = MBRouteRenderer.elevationLayerValues(elevated: elevated, height: height)
        for layer in [Constants.LayerIDs.lineLayer, Constants.LayerIDs.baseLineLayer, Constants.LayerIDs.animatedLineLayer] {
            try? mapView.mapboxMap.setLayerProperty(for: layer, property: "line-elevation-reference", value: values.lineReference)
            try? mapView.mapboxMap.setLayerProperty(for: layer, property: "line-z-offset", value: values.zOffset)
        }
        // Symbols ride the line: their reference is always `ground` (symbol layers have no "none"); a z-offset
        // of 0 leaves them on the ground plane, i.e. unchanged from a grounded route.
        for layer in [Constants.LayerIDs.stampLayer, Constants.LayerIDs.routeMarkerLayer] {
            try? mapView.mapboxMap.setLayerProperty(for: layer, property: "symbol-elevation-reference", value: values.symbolReference)
            try? mapView.mapboxMap.setLayerProperty(for: layer, property: "symbol-z-offset", value: values.zOffset)
        }
    }

    /// Drives continuous map rendering for the lifetime of a running animation, WITHOUT moving the camera:
    /// observe `onRenderFrameFinished` and request the next frame each time, so the map paints every frame the
    /// way it does during a camera fly. A per-frame layer-property write alone does not reliably wake an idle
    /// Mapbox map, so this is what keeps flow / pulse / comet flowing across an in-place, non-camera-moving
    /// re-render (options / icon toggle). Idempotent — safe to call on every re-render while animating.
    private func startRenderLoop() {
        guard renderLoopToken == nil, let mapView else { return }
        renderLoopToken = mapView.mapboxMap.onRenderFrameFinished.observe { [weak self] _ in
            self?.mapView?.mapboxMap.triggerRepaint()
        }
        mapView.mapboxMap.triggerRepaint()  // kickstart: one repaint → first frame → the loop then self-sustains
    }

    /// Stops the continuous-render loop so the map returns to on-demand rendering (idles) once no animation runs.
    private func stopRenderLoop() {
        renderLoopToken?.cancel()
        renderLoopToken = nil
    }

    /// Style-spec `rgba(...)` string for a `UIColor`. Normalises to sRGB first because `getRed(...)` fails
    /// (leaving the components at 0 → transparent) for non-RGB colours — grayscale like `UIColor.white` /
    /// `.black`, or Display P3 — which would otherwise make the comet invisible. Mirrors how `StyleColor(_:)`
    /// handles the line-color for flow / pulse.
    private static func rgbaString(from color: UIColor) -> String {
        var normalized = color
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = color.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) {
            normalized = UIColor(cgColor: converted)
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        normalized.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())), \(a))"
    }

    /// Re-commits only the route marker source, leaving every line / stamp layer — and the running animator —
    /// alone. The marker source is fully replaced by the new feature collection, so a marker the model no
    /// longer carries (an endpoint pin whose display rule just went out of its zoom range) disappears.
    func applyMarkers(model: RouteViewModelProducer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let mapView = self.mapView, mapView.mapboxMap.isStyleLoaded else { return }
            self.commitMarkers(model: model, on: mapView)
            // Nothing else in this pass wakes the map, and with no animation running there is no render loop
            // to pick the change up — so ask for the one frame that draws the toggled marker.
            mapView.mapboxMap.triggerRepaint()
        }
    }

    /// Registers the marker icons and commits the marker source — the marker slice of `applyOnMain`, extracted
    /// for readability.
    private func commitMarkers(model: RouteViewModelProducer, on mapView: MapView) {
        // Register the marker icons BEFORE committing the marker source. The symbol layer resolves its icon via
        // `Exp(.image){Exp(.id)}` when a feature is committed; registering the image first (as the location
        // renderer does) means that commit finds the image present and draws it at once. Register each
        // independently: a single odd raster makes Mapbox's addImage throw a StyleError, and one aborting throw
        // would suppress every remaining icon (dropping the pins while the labels still draw).
        for marker in [model.start, model.end].compactMap({ $0 }) + (model.stops ?? []) {
            guard let icon = marker.data[.icon] as? UIImage else { continue }
            do {
                try mapView.mapboxMap.addImage(icon, id: marker.id, sdf: false)
            } catch {
                MPLog.mapbox.error("Skipping invalid route marker image \(marker.id): \(error)")
            }
        }
        let markerJson = markersToJsonArray(start: model.start, end: model.end, stops: model.stops)
        do {
            let features = try JSONDecoder().decode([Feature].self, from: markerJson.data(using: .utf8)!)
            let geojson = GeoJSONObject.featureCollection(FeatureCollection(features: features))
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.routeMarkerSource, geoJSON: geojson)
            }
        } catch {
            MPLog.mapbox.error("Error updating start/end marker data in route renderer!")
        }
    }

    func moveCamera(points path: [CLLocationCoordinate2D], animate _: Bool, durationMs: Int, tilt: Float, fitMode: MPCameraViewFitMode, padding: UIEdgeInsets, maxZoom: Double?) {
        guard let mapView, path.count >= 2 else { return }

        let bounds = MPGeoBounds(points: path).adjustedTo(maxZoom: maxZoom, mapViewHeight: Double(mapView.frame.width), mapViewWidth: Double(mapView.frame.width))
        var bearing = Double.nan
        var pitch = Double(tilt)

        switch fitMode {
        case .northAligned:
            bearing = 0.0
            pitch = 0.0
        case .firstStepAligned:
            guard path.count >= 2 else { break }
            bearing = MPGeometryUtils.bearingBetweenPoints(from: path[0], to: path[1])
        case .startToEndAligned:
            bearing = MPGeometryUtils.bearingBetweenPoints(from: path[0], to: path.last!)
        case .none:
            return
        default:
            break
        }

        if !bearing.isNaN {
            do {
                var camOptions = try mapView.mapboxMap.camera(for: [bounds.southWest, bounds.northEast], camera: CameraOptions(bearing: bearing, pitch: pitch), coordinatesPadding: padding, maxZoom: nil, offset: nil)
                // `coordinatesPadding` only feeds the center/zoom
                // computation — per Mapbox v11 docs it is *not*
                // applied to the map, and the returned CameraOptions
                // has `padding == nil`. Without an explicit padding
                // here, fly(to:) would leave the map's existing
                // padding intact (e.g. `mapProvider.padding` that
                // MBCameraOperator's earlier move/animate calls have
                // persisted on the camera state), so the route would
                // be fit for (view - combinedPadding) but rendered
                // against (view - mapPadding) — a mismatch that
                // leaves an extra safe-area + renderer-padding margin
                // around the route. Also fixes the tilted-fit-mode
                // case where perspective stretches the near end
                // outside the visible region. Setting padding here
                // is a no-op when pitch is 0 and the existing camera
                // padding already equals `padding`.
                camOptions.padding = padding
                mapView.camera.fly(to: camOptions, duration: Double(durationMs) / 5000.0, completion: nil)
            } catch {
                MPLog.mapbox.error("Error trying to move Mapbox camera!")
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.clearOnMain()
        }
    }

    private func clearOnMain() {
        route = [CLLocationCoordinate2D]()
        valueAnimator?.invalidate()
        valueAnimator = nil
        stopRenderLoop()
        guard let mapView, mapView.mapboxMap.isStyleLoaded else { return }
        do {
            // Clear polyline
            let geom = LineString([]).geometry
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
            }
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.animatedLineSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.animatedLineSource, geoJSON: GeoJSONObject.geometry(geom))
            }

            // Clear markers
            let features = GeoJSONObject.featureCollection(FeatureCollection(features: [Feature]()))
            if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) {
                mapView.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.routeMarkerSource, geoJSON: features)
            }
            if mapView.mapboxMap.imageExists(withId: "start_marker") {
                try mapView.mapboxMap.removeImage(withId: "start_marker")
            }
            if mapView.mapboxMap.imageExists(withId: "end_marker") {
                try mapView.mapboxMap.removeImage(withId: "end_marker")
            }
            // Tear the stamp down explicitly — hide the layer and drop its registered image. The symbols also
            // vanish with the emptied lineSource, but don't rely on that; keep teardown symmetric with the
            // Google renderer and avoid leaking the last route's stamp image in the style registry.
            try? mapView.mapboxMap.setLayerProperty(for: Constants.LayerIDs.stampLayer, property: "visibility", value: "none")
            if mapView.mapboxMap.imageExists(withId: MBRouteRenderer.stampImageID) {
                try mapView.mapboxMap.removeImage(withId: MBRouteRenderer.stampImageID)
            }
        } catch {
            MPLog.mapbox.error("Error clearing route data from mapbox map!")
        }
    }

    private func markersToJsonArray(start: (any MPViewModel)?, end: (any MPViewModel)?, stops: [any MPViewModel]?) -> String {
        var jsonElements = [String]()

        for stop in stops ?? [] {
            guard let marker = stop.marker else { continue }
            jsonElements.append(marker.toGeoJson())
        }

        // Append when the view model exists (it is built only when there is something to draw). An origin /
        // destination display rule can be label-only (iconVisible = false / no iconUrl): it has no `.icon`
        // but a valid label, so gating on `.icon` would silently drop it on Mapbox even though Google draws it.
        if let start, let marker = start.marker {
            jsonElements.append(marker.toGeoJson())
        }

        if let end, let marker = end.marker {
            jsonElements.append(marker.toGeoJson())
        }

        var json = "["
        json.append(jsonElements.joined(separator: ","))
        json.append("]")

        return json
    }

}
