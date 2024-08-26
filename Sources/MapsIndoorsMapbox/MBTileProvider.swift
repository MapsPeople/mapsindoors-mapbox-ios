//
//  MBTileProvider.swift
//  MapsIndoorsMapbox
//
//  Created by Malte Myhlendorph on 22/09/2022.
//  Copyright © 2022 MapsPeople A/S. All rights reserved.
//

import Foundation
import MapboxMaps
import MapsIndoorsCore

class MBTileProvider {
    private weak var mapView: MapView?
    private weak var mapProvider: MapBoxProvider?
    public var _tileProvider: MPTileProvider
    private var rasterSource: RasterSource
    private var templateUrl: String!
    
    init(mapView: MapView?, tileProvider: MPTileProvider, mapProvider: MapBoxProvider) {
        self.mapView = mapView
        self.mapProvider = mapProvider
        _tileProvider = tileProvider
        rasterSource = RasterSource(id: Constants.SourceIDs.tileSource)
        setupLayer()
        update()
    }
    
    private func setupLayer() {
        if !(mapView?.mapboxMap.layerExists(withId: Constants.LayerIDs.tileLayer) ?? false) {
            let tileLayer = RasterLayer(id: Constants.LayerIDs.tileLayer, source: Constants.SourceIDs.tileSource)
            do {
                try mapView?.mapboxMap.addLayer(tileLayer)
            } catch {
                MPLog.mapbox.error(error.localizedDescription)
            }
        }
    }
    
    func update() {
        DispatchQueue.main.async {
            do {
                try self.updateSource()
                try self.updateLayer()
            } catch {
                MPLog.mapbox.error("Error updating tile layer/source: \(error.localizedDescription)")
            }
        }
    }
    
    private func updateSource() throws {
        if templateUrl != _tileProvider.templateUrl() {
            templateUrl = _tileProvider.templateUrl()
            rasterSource.tiles = [templateUrl]
            rasterSource.tileSize = _tileProvider.tileSize()
            rasterSource.volatile = false
        }
        
        if self.mapView?.mapboxMap.sourceExists(withId: Constants.SourceIDs.tileSource) == false {
            try self.mapView?.mapboxMap.addSource(rasterSource)
            return
        }

        try self.mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.tileLayer, type: RasterLayer.self) { updateLayer in
            
            if mapView?.mapboxMap.layerExists(withId: Constants.LayerIDs.polygonFillLayer) ?? false {
                do {
                    try mapView?.mapboxMap.moveLayer(withId: Constants.LayerIDs.tileLayer, to: .below(Constants.LayerIDs.polygonFillLayer))
                } catch {
                    MPLog.mapbox.error(error.localizedDescription)
                }
            }
            updateLayer.source = .none
        }
        
        try self.mapView?.mapboxMap.removeSource(withId: Constants.SourceIDs.tileSource)
        try self.mapView?.mapboxMap.addSource(rasterSource)

    }
    
    private func updateLayer() throws {
        try self.mapView?.mapboxMap.updateLayer(withId: Constants.LayerIDs.tileLayer, type: RasterLayer.self) { updateLayer in
            updateLayer.source = Constants.SourceIDs.tileSource
            updateLayer.rasterFadeDuration = .constant(0.5)
            updateLayer.slot = .middle
            
            if let transitionLevel = mapProvider?.transitionLevel {
                let stops: [Double: Exp] = [
                    (Double(transitionLevel)): Exp(.literal) { 0.0 },
                    (Double(transitionLevel)+1.0): Exp(.literal) { 1.0 }
                ]
                
                updateLayer.rasterOpacity = .expression(
                    Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.zoom)
                        stops
                    }
               )
            }
        }
    }
    
}
