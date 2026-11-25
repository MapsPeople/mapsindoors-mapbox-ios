import Foundation
import MapsIndoorsCore

class MBDistanceMatrixService: MPExternalDistanceMatrixService {
    // Limitaions: https://docs.mapbox.com/api/navigation/matrix/#matrix-api-restrictions-and-limits
    // 25 input coordinates for the walking, cycling and driving profiles; driving-traffic, which is not used, takes 10.
    private let maxWaypoints = 25

    private let accessToken: String

    required init(accessToken: String) {
        self.accessToken = accessToken
    }

    func query(origins: [CLLocationCoordinate2D], destinations: [CLLocationCoordinate2D], config: MPDirectionsConfig) async throws -> MPDistanceMatrixResult? {
        let profile =
            switch config.travelMode {
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
        // Only the origin-to-destination pairs are used, and Mapbox bills every pair it computes, so it is asked for
        // those alone: the origins are the sources and the destinations the destinations, by index in `coordinates`.
        var sourceIndices = Array(origins.indices)
        let destinationIndices = destinations.indices.map { origins.count + $0 }
        // Mapbox refuses a matrix of fewer than 2 pairs, and one origin with one destination (outside to a venue with
        // one entrance, or back) is 1. The destination is then a source too: its row comes after the origins' and is
        // not read.
        if sourceIndices.count * destinationIndices.count < 2 {
            sourceIndices.append(contentsOf: destinationIndices)
        }
        let sources = sourceIndices.map { "\($0)" }.joined(separator: ";")

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "api.mapbox.com"
        urlComponents.path = "/directions-matrix/v1/\(profile)/\(coordinates)"
        urlComponents.queryItems = [
            URLQueryItem(name: "sources", value: sources),
            URLQueryItem(name: "destinations", value: destinationIndices.map { "\($0)" }.joined(separator: ";")),
            URLQueryItem(name: "annotations", value: "distance,duration"),
            URLQueryItem(name: "access_token", value: accessToken),
        ]
        // No arrival or departure time, even when the query has one. The Matrix API has no `arrive_by`, and takes
        // `depart_at` only for accounts in Mapbox's beta of it; any other request with either is answered with HTTP 422.
        // Routing uses the matrix only to rank a venue's entrances, and the directions request for the chosen entrances
        // carries the time.

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

    func pruneDistanceMatrixDimensions(
        origins: [MPPoint],
        destinations: [MPPoint]
    ) -> ([MPPoint], [MPPoint]) {
        var resultingOrigins = origins
        var resultingDestinations = destinations

        // Prune origins
        let destinationsAvg = MPPoint(
            coordinate:
                CLLocationCoordinate2D(
                    latitude: (destinations.map(\.latitude).reduce(0.0, +)) / Double(destinations.count),
                    longitude: (destinations.map(\.longitude).reduce(0.0, +)) / Double(destinations.count)))

        var originsDistanceTuple = [(MPPoint, Double)]()
        for origin in origins {
            let distance = destinationsAvg.distanceTo(origin)
            originsDistanceTuple.append((origin, distance))
        }

        resultingOrigins = originsDistanceTuple.sorted { a, b in a.1 < b.1 }.map(\.0)

        // Prune destinations
        let originsAvg = MPPoint(
            coordinate:
                CLLocationCoordinate2D(
                    latitude: (origins.map(\.latitude).reduce(0.0, +)) / Double(origins.count),
                    longitude: (origins.map(\.longitude).reduce(0.0, +)) / Double(origins.count)))

        var distinationsDistanceTuple = [(MPPoint, Double)]()
        for destination in destinations {
            let distance = originsAvg.distanceTo(destination)
            distinationsDistanceTuple.append((destination, distance))
        }

        resultingDestinations = distinationsDistanceTuple.sorted { a, b in a.1 < b.1 }.map(\.0)

        // While the total size exceeds the max, we drop the last entry for the largest dimension. Mapbox counts the
        // coordinates of a request, origins and destinations together, not the cells of the matrix (SPEX-3131).
        while resultingOrigins.count + resultingDestinations.count > maxWaypoints {
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
    /// `null` for a pair Mapbox can't route.
    let distances: [[Double?]]?
    let destinations: [Destination]?
    /// `null` for a pair Mapbox can't route.
    let durations: [[Double?]]?
    let sources: [Destination]?
}

struct Destination: Codable {
    let distance: Double?
    let name: String?
    let location: [Double]?
}

extension MapboxDistanceMatrix {
    /// Reads the answer to a request whose sources are the origins and whose destinations are the destinations, as
    /// `MBDistanceMatrixService.query` sends it: row `i` is from origin `i`, element `k` to destination `k`. Rows after
    /// the origins' (the destination asked for as a source too, when there is one origin and one destination) are not
    /// read.
    ///
    /// A pair Mapbox can't route is `null` in the answer. It becomes an element whose status is not "OK", as the Google
    /// provider returns one, so routing skips that pair and still uses the rest of the matrix.
    func asMPDistanceMatrix(originsCount: Int) -> MPDistanceMatrixResult {
        let mpMatrix = MPDistanceMatrixResult()

        let destinationsCount = distances?.first?.count ?? 0
        mpMatrix.origin_addresses = sources?.prefix(originsCount).map { $0.name ?? "" } ?? []
        mpMatrix.destination_addresses = destinations?.map { $0.name ?? "" } ?? []
        mpMatrix.status = "OK"

        // Assuming distance and duration matrices are same dimensions, we can safely index on duration simultaneously
        mpMatrix.rows = [MPDistanceMatrixRows]()
        if let distanceMatrix = distances,
            let durationMatrix = durations
        {
            for i in 0..<originsCount {
                var mpRow = MPDistanceMatrixRows()
                mpRow.elements = [MPDistanceMatrixElements]()
                for k in 0..<destinationsCount {
                    var mpElem = MPDistanceMatrixElements()

                    if let distance = distanceMatrix[i][k], let duration = durationMatrix[i][k] {
                        mpElem.distance = MPRoutePropertyInternal(withValue: NSNumber(value: distance), withText: Measurement(value: distance, unit: UnitLength.meters).converted(to: UnitLength.kilometers).description)
                        mpElem.duration = MPRoutePropertyInternal(withValue: NSNumber(value: duration), withText: Measurement(value: duration, unit: UnitDuration.seconds).converted(to: UnitDuration.hours).description)
                        mpElem.status = "OK"
                    } else {
                        mpElem.status = "ZERO_RESULTS"
                    }

                    mpRow.elements?.append(mpElem)
                }
                if !mpRow.elements!.isEmpty {
                    mpMatrix.rows?.append(mpRow)
                }
            }
        }

        return mpMatrix
    }
}
