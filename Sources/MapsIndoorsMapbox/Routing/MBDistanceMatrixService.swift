import Foundation
import MapsIndoorsCore

class MBDistanceMatrixService: MPExternalDistanceMatrixService {
    
    // Limitaions: https://docs.mapbox.com/api/navigation/matrix/#matrix-api-restrictions-and-limits
    private let maxWaypoints = 25

    private let accessToken: String
        
    required init(accessToken: String) {
        self.accessToken = accessToken
    }
    
    func query(origins: [CLLocationCoordinate2D], destinations: [CLLocationCoordinate2D], config: MPDirectionsConfig) async throws -> MPDistanceMatrixResult? {
        
        let profile = switch config.travelMode {
        case .walking:
            "mapbox/walking"
        case .bicycling:
            "mapbox/cycling"
        case .driving:
            "mapbox/driving"
        default:
            ""
        }

        let coordinates = (origins + destinations).map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "api.mapbox.com"
        urlComponents.path = "/directions-matrix/v1/\(profile)/\(coordinates)"
        urlComponents.queryItems = [
            URLQueryItem(name: "sources", value: "all"),
            URLQueryItem(name: "destinations", value: "all"),
            URLQueryItem(name: "annotations", value: "distance,duration"),
            URLQueryItem(name: "access_token", value: self.accessToken)
        ]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        if let arrivalTime = config.arrival {
            urlComponents.queryItems?.append(URLQueryItem(name: "arrive_by", value: dateFormatter.string(from: arrivalTime)))
        } else if let departureTime = config.departure {
            urlComponents.queryItems?.append(URLQueryItem(name: "depart_at", value: dateFormatter.string(from: departureTime)))
        }

        guard let url = urlComponents.url else {
            MPLog.mapbox.error("Failed to construct URL query for the Mapbox Distance Matrix API!")
            throw MPError.directionsMatrixNotFound
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) == false {
            MPLog.mapbox.error("Failed request to the Mapbox Distance Matrix API - code: \(httpResponse.statusCode)")
            throw MPError.directionsMatrixNotFound
        }
        
        do {
            let matrixResponse = try JSONDecoder().decode(MapboxDistanceMatrix.self, from: data)
            let result = matrixResponse.asMPDistanceMatrix(originsCount: origins.count)
            return result
        } catch {
            MPLog.mapbox.error("Failed deserialize the response from the Mapbox Distance Matrix API! \(error)")
            throw MPError.directionsMatrixNotFound
        }
    }
    
    func pruneDistanceMatrixDimensions(origins: [MPPoint],
                                       destinations: [MPPoint]) -> ([MPPoint], [MPPoint]) {
        var resultingOrigins = origins
        var resultingDestinations = destinations
        
        // Prune origins
        let destinationsAvg = MPPoint(coordinate:
                                        CLLocationCoordinate2D(latitude: (destinations.map({$0.latitude}).reduce(0.0, +)) / Double(destinations.count),
                                                               longitude: (destinations.map({$0.longitude}).reduce(0.0, +)) / Double(destinations.count)))
        
        var originsDistanceTuple = [(MPPoint, Double)]()
        for origin in origins {
            let distance = destinationsAvg.distanceTo(origin)
            originsDistanceTuple.append((origin, distance))
        }
        
        resultingOrigins = originsDistanceTuple.sorted { a, b in a.1 < b.1 }.map({$0.0})
        
        // Prune destinations
        let originsAvg = MPPoint(coordinate:
                                    CLLocationCoordinate2D(latitude: (origins.map({$0.latitude}).reduce(0.0, +)) / Double(origins.count),
                                                                    longitude: (origins.map({$0.longitude}).reduce(0.0, +)) / Double(origins.count)))
        
        var distinationsDistanceTuple = [(MPPoint, Double)]()
        for destination in destinations {
            let distance = originsAvg.distanceTo(destination)
            distinationsDistanceTuple.append((destination, distance))
        }
        
        resultingDestinations = distinationsDistanceTuple.sorted { a, b in a.1 < b.1 }.map({$0.0})
        
        // While the total size exceeds the max, we drop the last entry for the largest dimension
        while resultingOrigins.count * resultingDestinations.count >= maxWaypoints {
            if resultingOrigins.count > resultingDestinations.count {
                resultingOrigins = resultingOrigins.dropLast()
            } else {
                resultingDestinations = resultingDestinations.dropLast()
            }
        }
        
        return (resultingOrigins, resultingDestinations)
    }
    
}

struct MapboxDistanceMatrix: Codable {
    let code: String?
    let distances: [[Double]]?
    let destinations: [Destination]?
    let durations: [[Double]]?
    let sources: [Destination]?
}

struct Destination: Codable {
    let distance: Double?
    let name: String?
    let location: [Double]?
}

extension MapboxDistanceMatrix {
    
    func asMPDistanceMatrix(originsCount: Int) -> MPDistanceMatrixResult {
        var mpMatrix = MPDistanceMatrixResult()
        
        let destinations = (self.distances?.count ?? 0) - originsCount
        mpMatrix.origin_addresses = self.sources?[..<originsCount].map { $0.name ?? "" } ?? []
        mpMatrix.destination_addresses = self.destinations?.dropFirst(originsCount).map { $0.name ?? "" } ?? []
        mpMatrix.status = "OK"

        // Assuming distance and duration matrices are same dimensions, we can safely index on duration simultaneously
        mpMatrix.rows = [MPDistanceMatrixRows]()
        if let distanceMatrix = self.distances,
           let durationMatrix = self.durations {
            for i in 0..<originsCount {
                var mpRow = MPDistanceMatrixRows()
                mpRow.elements = [MPDistanceMatrixElements]()
                for j in originsCount..<(originsCount+destinations) {
                    let distance = distanceMatrix[j][i]
                    let duration = durationMatrix[j][i]
                    
                    var mpDist = MPRoutePropertyInternal(withValue: NSNumber(value: distance), withText: Measurement(value: distance, unit: UnitLength.meters).converted(to: UnitLength.kilometers).description)
                    
                    var mpDur = MPRoutePropertyInternal(withValue: NSNumber(value: duration), withText: Measurement(value: duration, unit: UnitDuration.seconds).converted(to: UnitDuration.hours).description)
                    
                    var mpElem = MPDistanceMatrixElements()
                    mpElem.distance = mpDist
                    mpElem.duration = mpDur
                    
                    mpElem.status = "OK"
                    
                    mpRow.elements?.append(mpElem)
                }
                if mpRow.elements!.count > 0 {
                    mpMatrix.rows?.append(mpRow)
                }
            }
        }
        
        return mpMatrix
    }
    
}
