//
//  MBRouteRenderer.swift
//  MapsIndoorsMapbox
//
//  Created by Frederik Hansen on 12/10/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapboxMaps
import MapsIndoorsCore
import ValueAnimator

extension BinaryFloatingPoint {
    var degrees: Self {
        return self * 180.0 / .pi
    }
    var radians: Self {
        return self * .pi / 180.0
    }
}

class MBRouteRenderer: MPRouteRenderer {
    
    private weak var mapView: MapView?
    var routeMarkerDelegate: MPRouteMarkerDelegate?
    
    private var valueAnimator: ValueAnimator?
    
    private var route = [CLLocationCoordinate2D]()
    
    required init(mapView: MapView?) {
        self.mapView = mapView
        configureSources()
    }
    
    func configureSources() {
        guard let mapView else { 
            MPLog.mapbox.debug("Error setting up sources in route renderer!")
            return
        }
        
        if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) == false {
            var lineSource = GeoJSONSource(id: Constants.SourceIDs.lineSource)
            lineSource.data = .geometry(Geometry.multiPoint(MultiPoint([LocationCoordinate2D]())))
            do {
                try mapView.mapboxMap.addSource(lineSource)
            } catch {
                MPLog.mapbox.debug("Error setting up line source in route renderer!")
            }
        }
        
        if mapView.mapboxMap.sourceExists(withId: Constants.SourceIDs.animatedLineSource) == false {
            var animatedSource = GeoJSONSource(id: Constants.SourceIDs.animatedLineSource)
            animatedSource.data = .geometry(Geometry.multiPoint(MultiPoint([LocationCoordinate2D]())))
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
    
    func apply(model: RouteViewModelProducer, animate: Bool, duration: TimeInterval, repeating: Bool, primaryColor: UIColor, secondaryColor: UIColor, primaryWidth: Float, secondaryWidth: Float, pathSmoothing: Bool) {
        
        configureSources()
        
        route = model.polyline
        
        // Draw line
        let geom = Geometry.multiPoint(MultiPoint(route))
        
        do {
            if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
                try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.routeMarkerLayer, type: SymbolLayer.self) { symbolLayer in
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
                    symbolLayer.textSize = .constant(14)
                    symbolLayer.textColor = .constant(.init(.black))
                    symbolLayer.textHaloColor = .constant(.init(.white))
                    symbolLayer.textHaloWidth = .constant(1.0)
                    symbolLayer.textHaloBlur = .constant(1.0)
                }
            }
        } catch {
            MPLog.mapbox.error("Error updating route polyline in route renderer!")
        }
        
        do {
            if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
                try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.lineLayer, type: LineLayer.self) { lineLayer in
                    lineLayer.lineColor = .constant(StyleColor(primaryColor))
                    lineLayer.lineWidth = .constant(Double(primaryWidth))
                    lineLayer.lineCap = .constant(.butt)
                    lineLayer.lineJoin = .constant(.round)
                }
            }
        } catch {
            MPLog.mapbox.error("Error updating route polyline in route renderer!")
        }
        
        // Add marker json
        let markerJson = markersToJsonArray(start: model.start, end: model.end, stops: model.stops)
        do {
            let features = try JSONDecoder().decode([Feature].self, from: markerJson.data(using: .utf8)!)
            let geojson = GeoJSONObject.featureCollection(FeatureCollection(features: features))
            if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.routeMarkerSource, geoJSON: geojson)
            }
        } catch {
            MPLog.mapbox.error("Error updating start/end marker data in route renderer!")
        }
        
        // Add marker icons
        do {
            if let start = model.start {
                if let icon = start.data[.icon] as? UIImage {
                    try mapView?.mapboxMap.addImage(icon, id: start.id, sdf: false)
                }
            }
            if let end = model.end {
                if let icon = end.data[.icon] as? UIImage {
                    try mapView?.mapboxMap.addImage(icon, id: end.id, sdf: false)
                }
            }
            for stop in model.stops ?? [] {
                if let icon = stop.data[.icon] as? UIImage {
                    try mapView?.mapboxMap.addImage(icon, id: stop.id, sdf: false)
                }
            }
        } catch {
            MPLog.mapbox.error("Error updating start/end marker icons in route renderer!")
        }
        
        if animate {
            
            do {
                try mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.animatedLineLayer, type: LineLayer.self) { lineLayer in
                    lineLayer.lineColor = .constant(StyleColor(secondaryColor))
                    lineLayer.lineWidth = .constant(Double(secondaryWidth))
                    lineLayer.lineCap = .constant(.butt)
                    lineLayer.lineJoin = .constant(.round)
                }
            } catch {
                MPLog.mapbox.error("Error updating animated route polyline in route renderer!")
            }
            
            //https://github.com/brownsoo/ValueAnimator/tree/0.6.7
            valueAnimator = ValueAnimator.animate("val", from: 0.0, to: 1.0, duration: duration,
                                                  easing: EaseLinear.easeInOut(),
                onChanged: { _, v in
                    DispatchQueue.global(qos: .userInteractive).async {
                        var points = [CLLocationCoordinate2D]()
                        var totalDistance = 0.0
                        var prevPoint: CLLocationCoordinate2D? = nil
                        let routePoints = self.route
                        
                        for point in routePoints {
                            if prevPoint != nil {
                                totalDistance += MPGeometryUtils.distance(from: MPGeoPoint(coordinate: prevPoint!), to: MPGeoPoint(coordinate: point))
                            }
                            prevPoint = point
                        }
                        
                        let stopDistance = v.value * totalDistance
                        var distance = 0.0
                        
                        prevPoint = nil
                        for i in stride(from: 0, through: routePoints.count - 1, by: 1) {
                            let nextPoint = routePoints[i]
                            if i == 0 || v.value == 1.0 {
                                points.append(nextPoint)
                            } else {
                                let lastPoint = routePoints[i-1]
                                var nextDistance = MPGeometryUtils.distance(from: MPGeoPoint(coordinate: lastPoint), to: MPGeoPoint(coordinate: nextPoint))
                                if distance + nextDistance > stopDistance {
                                    nextDistance = stopDistance - distance
                                    let bearing = MPGeometryUtils.bearingBetweenPoints(from: lastPoint, to: nextPoint)
                                    let computedPoint = self.computeOffset(from: lastPoint, dist: nextDistance, head: bearing)
                                    points.append(computedPoint)
                                    break
                                } else {
                                    points.append(nextPoint)
                                }
                                distance += nextDistance
                            }
                        }
                        
                        DispatchQueue.main.async {
                            let geom = Geometry.multiPoint(MultiPoint(points))
                            if self.mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.animatedLineSource) ?? false {
                                self.mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.animatedLineSource, geoJSON: GeoJSONObject.geometry(geom))
                            }
                        }
                        
                    }
                }, option: ValueAnimator.OptionBuilder().setRepeatInfinitely(repeating).build())
            
            self.valueAnimator?.resume()
        }
        
    }
    
    func moveCamera(points path: [CLLocationCoordinate2D], animate: Bool, durationMs: Int, tilt: Float, fitMode: MPCameraViewFitMode, padding: UIEdgeInsets) {
        guard path.count >= 2 else { return }
        
        let bounds = MPGeoBounds(points: path)
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
                if let camOptions = try mapView?.mapboxMap.camera(for: [bounds.southWest, bounds.northEast], camera: CameraOptions(bearing: bearing, pitch: pitch), coordinatesPadding: padding, maxZoom: nil, offset: nil) {
                    mapView?.camera.fly(to: camOptions, duration: Double(durationMs)/5000.0, completion: nil)
                }
            } catch {
                MPLog.mapbox.error("Error trying to move Mapbox camera!")
            }
        }
    }
    
    func clear() {
        route = [CLLocationCoordinate2D]()
        valueAnimator?.pause()
        valueAnimator = nil
        do {
            // Clear polyline
            let geom = Geometry.multiPoint(MultiPoint([LocationCoordinate2D]()))
            if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.lineSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.lineSource, geoJSON: GeoJSONObject.geometry(geom))
            }
            if mapView?.mapboxMap?.sourceExists(withId: Constants.SourceIDs.animatedLineSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.animatedLineSource, geoJSON: GeoJSONObject.geometry(geom))
            }
            
            // Clear markers
            let features = GeoJSONObject.featureCollection(FeatureCollection(features: [Feature]()))
            if mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.routeMarkerSource) ?? false {
                mapView?.mapboxMap.updateGeoJSONSource(withId: Constants.SourceIDs.routeMarkerSource, geoJSON: features)
            }
            if mapView?.mapboxMap.imageExists(withId: "start_marker") ?? false {
                try mapView?.mapboxMap.removeImage(withId: "start_marker")
            }
            if mapView?.mapboxMap.imageExists(withId: "end_marker") ?? false {
                try mapView?.mapboxMap.removeImage(withId: "end_marker")
            }
        } catch {
            MPLog.mapbox.error("Error clearing route data from mapbox map!")
        }
    }
    
    private func markersToJsonArray(start: (any MPViewModel)?, end: (any MPViewModel)?, stops: [(any MPViewModel)]?) -> String {
        var jsonElements = [String]()
        
        for stop in stops ?? [] {
            jsonElements.append(stop.marker!.toGeoJson())
        }
        
        if start != nil && start!.data[.icon] != nil {
            jsonElements.append(start!.marker!.toGeoJson())
        }
        
        if end != nil && end!.data[.icon] != nil {
            jsonElements.append(end!.marker!.toGeoJson())
        }
        
        var json = "["
        json.append(jsonElements.joined(separator: ","))
        json.append("]")

        return json
    }
        
    // Calculation from Google's Spherical utils, earth radius from MapboxSDK v9
    private func computeOffset(from: CLLocationCoordinate2D, dist: Double, head: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6378137.0
        let distance = dist / earthRadius
        let heading = head.radians
        let fromLat = from.latitude.radians
        let fromLng = from.longitude.radians
        let cosDistance = cos(distance)
        let sinDistance = sin(distance)
        let sinFromLat = sin(fromLat)
        let cosFromLat = cos(fromLat)
        let sinLat = cosDistance * sinFromLat + sinDistance * cosFromLat * cos(heading)
        let dLng = atan2(sinDistance * cosFromLat * sin(heading), cosDistance - sinFromLat * sinLat)
        return CLLocationCoordinate2D(latitude: asin(sinLat).degrees, longitude: (fromLng + dLng).degrees)
    }
    
}
