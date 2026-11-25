// https://github.com/raphaelmor/Polyline/blob/master/Sources/Polyline/Polyline.swift - cut down to the decoder, which is
// all the SDK uses: the encoder, the levels and the CLLocation and MapKit conveniences are removed.
// Polyline.swift
//
// Copyright (c) 2015 Raphaël Mor
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CoreLocation
import Foundation

/// Decodes a polyline `String` to a `[CLLocationCoordinate2D]`.
///
/// it is aims to produce the same results as google's iOS sdk not as the online
/// tool which is fuzzy when it comes to rounding values
///
/// it is based on google's algorithm that can be found here :
///
/// :see: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
internal struct Polyline {
    /// The array of coordinates (nil if polyline cannot be decoded)
    let coordinates: [CLLocationCoordinate2D]?

    /// Decodes a polyline `String`
    ///
    /// - parameter encodedPolyline: The polyline that you want to decode
    /// - parameter precision: The precision used for decoding (default: `1e5`)
    internal init(encodedPolyline: String, precision: Double = 1e5) {
        coordinates = decodePolyline(encodedPolyline, precision: precision)
    }
}

/// This function decodes a `String` to a `[CLCLLocationCoordinate2D]?`
///
/// - parameter encodedPolyline: `String` representing the encoded Polyline
/// - parameter precision: The precision used to decode coordinates (default: `1e5`)
///
/// - returns: A `[CLCLLocationCoordinate2D]` representing the decoded polyline if valid, `nil` otherwise
internal func decodePolyline(_ encodedPolyline: String, precision: Double = 1e5) -> [CLLocationCoordinate2D]? {
    let data = encodedPolyline.data(using: .utf8)!
    return data.withUnsafeBytes { byteArray -> [CLLocationCoordinate2D]? in
        let length = data.count
        var position = 0

        var decodedCoordinates = [CLLocationCoordinate2D]()

        var lat = 0.0
        var lon = 0.0

        while position < length {
            do {
                let resultingLat = try decodeSingleCoordinate(byteArray: byteArray, length: length, position: &position, precision: precision)
                lat += resultingLat

                let resultingLon = try decodeSingleCoordinate(byteArray: byteArray, length: length, position: &position, precision: precision)
                lon += resultingLon
            } catch {
                return nil
            }

            decodedCoordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }

        return decodedCoordinates
    }
}

// We use a byte array (UnsafePointer<Int8>) here for performance reasons. Check with swift 2 if we can
// go back to using [Int8]
private func decodeSingleCoordinate(byteArray: UnsafeRawBufferPointer, length: Int, position: inout Int, precision: Double = 1e5) throws -> Double {
    guard position < length else { throw PolylineError.singleCoordinateDecodingError }

    let bitMask = Int8(0x1F)

    var coordinate: Int32 = 0

    var currentChar: Int8
    var componentCounter: Int32 = 0
    var component: Int32 = 0

    repeat {
        currentChar = Int8(byteArray[position]) - 63
        component = Int32(currentChar & bitMask)
        coordinate |= (component << (5 * componentCounter))
        position += 1
        componentCounter += 1
    } while ((currentChar & 0x20) == 0x20) && (position < length) && (componentCounter < 6)

    // A last chunk that still continues means the value is not complete: it ran past six chunks, which no 32-bit
    // value needs, or the input ended inside it. Decoding what was read gives a wrong coordinate (SPEX-3148).
    if (currentChar & 0x20) == 0x20 {
        throw PolylineError.singleCoordinateDecodingError
    }

    if (coordinate & 0x01) == 0x01 {
        coordinate = ~(coordinate >> 1)
    } else {
        coordinate = coordinate >> 1
    }

    return Double(coordinate) / precision
}

enum PolylineError: Error {
    case singleCoordinateDecodingError
}
