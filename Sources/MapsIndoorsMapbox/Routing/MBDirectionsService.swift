import Foundation
import MapsIndoorsCore

class MBDirectionsService: MPExternalDirectionsService {
    private let accessToken: String

    required init(accessToken: String) {
        self.accessToken = accessToken
    }

    func query(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, config: MPDirectionsConfig) async throws -> MPRoute? {
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

        let originString = "\(origin.longitude),\(origin.latitude)"
        let destinationString = "\(destination.longitude),\(destination.latitude)"
        let coordinates = "\(originString);\(destinationString)"

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "api.mapbox.com"
        urlComponents.path = "/directions/v5/\(profile)/\(coordinates)"
        urlComponents.queryItems = [
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "overview", value: "simplified"),
            URLQueryItem(name: "geometries", value: "polyline"),
            URLQueryItem(name: "alternatives", value: "false"),
            URLQueryItem(name: "language", value: config.language ?? "en"),
            URLQueryItem(name: "access_token", value: accessToken),
        ]

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        if let arrivalTime = config.arrival {
            urlComponents.queryItems?.append(URLQueryItem(name: "arrive_by", value: dateFormatter.string(from: arrivalTime)))
        } else if let departureTime = config.departure {
            urlComponents.queryItems?.append(URLQueryItem(name: "depart_at", value: dateFormatter.string(from: departureTime)))
        }

        guard let url = urlComponents.url else {
            MPLog.mapbox.error("Failed to construct URL query for the Mapbox Directions API!")
            throw MPError.directionsRouteNotFound
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) == false {
            MPLog.mapbox.error("Failed request to the Mapbox Directions API - code: \(httpResponse.statusCode)")
            throw MPError.directionsRouteNotFound
        }

        do {
            let directionsResponse = try JSONDecoder().decode(MapboxDirections.self, from: data)
            let result = directionsResponse.routes?.first?.toMPRoute(travelMode: config.travelMode.description)
            return result
        } catch {
            MPLog.mapbox.error("Failed deserialize the response from the Mapbox Directions API! \(error)")
            throw MPError.directionsRouteNotFound
        }
    }
}

extension Route {
    func toMPRoute(travelMode: String) -> MPRouteInternal {
        let mpRoute = MPRouteInternal()

        for mapboxLeg in legs ?? [] {
            let mpLeg = MPRouteLegInternal()
            mpLeg.distance = (mapboxLeg.distance ?? 0) as NSNumber
            mpLeg.duration = (mapboxLeg.duration ?? 0) as NSNumber

            mpLeg.start_address = mapboxLeg.summary ?? ""
            mpLeg.end_address = mapboxLeg.summary ?? ""

            for mapboxstep in mapboxLeg.steps ?? [] {
                let mpStep = MPRouteStepInternal()
                if let instruction = mapboxstep.maneuver?.instruction, let streetName = mapboxstep.name, !streetName.isEmpty,
                    mapboxstep.maneuver?.type != "arrive" && mapboxstep.maneuver?.type != "depart",
                    instruction.range(of: streetName, options: .caseInsensitive) == nil
                {
                    mpStep.html_instructions = "\(instruction) on \(streetName)"
                } else {
                    mpStep.html_instructions = mapboxstep.maneuver?.instruction ?? ""
                }
                if let type = mapboxstep.maneuver?.type, type == "arrive" || type == "depart" {
                    mpStep.maneuver = type
                } else {
                    mpStep.maneuver = mapboxstep.maneuver?.modifier ?? mapboxstep.maneuver?.type ?? ""
                }
                mpStep.travel_mode = travelMode
                mpStep.distance = (mapboxstep.distance ?? 0) as NSNumber
                mpStep.duration = (mapboxstep.duration ?? 0) as NSNumber

                if let lineString = mapboxstep.geometry {
                    let line = Polyline(encodedPolyline: lineString).coordinates

                    var geometry = [MPRouteCoordinateInternal]()
                    for point in line ?? [] {
                        let x = MPRouteCoordinateInternal()
                        x.lat = point.latitude as NSNumber
                        x.lng = point.longitude as NSNumber
                        x.zLevel = 0.0
                        geometry.append(x)
                    }
                    mpStep.geometry = geometry

                    if let first = geometry.first {
                        mpStep.start_location = first
                    }
                    if let last = geometry.last {
                        mpStep.end_location = last
                    }
                } else if let maneuverLocation = mapboxstep.maneuver?.location, maneuverLocation.count == 2 {
                    let coord = MPRouteCoordinateInternal()
                    coord.lng = maneuverLocation[0] as NSNumber
                    coord.lat = maneuverLocation[1] as NSNumber
                    coord.zLevel = 0.0
                    mpStep.start_location = coord
                    mpStep.end_location = coord
                } else {
                    MPLog.mapbox.error("Unable to deserialize directions geometry!")
                }
                mpLeg.addStep(mpStep)
            }

            if let startLocation = mpLeg.steps.first?.start_location {
                let legStart = MPRouteCoordinateInternal()
                legStart.lat = startLocation.lat as NSNumber
                legStart.lng = startLocation.lng as NSNumber
                legStart.zLevel = 0.0 as NSNumber
                mpLeg.start_location = legStart
            }

            if let endLocation = mpLeg.steps.last?.end_location {
                let legEnd = MPRouteCoordinateInternal()
                legEnd.lat = endLocation.lat as NSNumber
                legEnd.lng = endLocation.lng as NSNumber
                legEnd.zLevel = 0.0 as NSNumber
                mpLeg.end_location = legEnd
            }

            mpLeg.routeLegType = .External
            mpRoute.addLeg(mpLeg)
        }

        return mpRoute
    }
}

struct MapboxDirections: Codable {
    let routes: [Route]?
    let code: String?
}

struct Route: Codable {
    let weightName: String?
    let weight: Double?
    let duration: Double?
    let distance: Double?
    let legs: [Leg]?
    let geometry: String?
}

struct Leg: Codable {
    let weight: Double?
    let duration: Double?
    let steps: [Step]?
    let distance: Double?
    let summary: String?
}

struct Step: Codable {
    let maneuver: Maneuver?
    let name: String?
    let duration: Double?
    let distance: Double?
    let weight: Double?
    let geometry: String?
    let ref: String?
}

struct Maneuver: Codable {
    let type: String?
    let instruction: String?
    let bearingAfter: Int?
    let bearingBefore: Int?
    let location: [Double]?
    let modifier: String?
}
