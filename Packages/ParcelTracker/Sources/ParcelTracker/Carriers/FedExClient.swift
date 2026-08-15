import Foundation

/// Reads parcel status from FedEx.
///
/// FedEx issues a bearer token from an API key and secret, good for an hour,
/// so the token is cached and refreshed a little before it lapses rather than
/// fetched per request.
public actor FedExClient: CarrierClient {
    public nonisolated var carrier: Carrier { .fedex }

    private let apiKey: String
    private let apiSecret: String
    private let baseURL: URL
    private let session: URLSession

    private var token: String?
    private var tokenExpiry: Date?

    public init(
        apiKey: String,
        apiSecret: String,
        baseURL: URL = URL(string: "https://apis.fedex.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.baseURL = baseURL
        self.session = session
    }

    public func track(_ trackingNumber: String) async throws -> TrackingResult {
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw CarrierError.missingCredentials(.fedex)
        }

        let token = try await authToken()
        var request = URLRequest(url: baseURL.appending(path: "track/v1/trackingnumbers"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en_US", forHTTPHeaderField: "X-locale")
        request.httpBody = try JSONEncoder().encode(
            TrackRequest(
                includeDetailedScans: true,
                trackingInfo: [.init(trackingNumberInfo: .init(trackingNumber: trackingNumber))]
            )
        )

        let data = try await perform(request)
        let payload = try decode(TrackResponse.self, from: data)

        guard let result = payload.output?.completeTrackResults?.first?.trackResults?.first else {
            throw CarrierError.notFound
        }

        // FedEx reports a per-parcel error here rather than as an HTTP status.
        if let error = result.error {
            throw error.code == "TRACKING.TRACKINGNUMBER.NOTFOUND"
                ? CarrierError.notFound
                : CarrierError.network(error.message ?? "FedEx could not read that number.")
        }

        // Keep the carrier's ordering: several scans can share a timestamp.
        let events = (result.scanEvents ?? []).enumerated().compactMap { index, payload in
            Self.event(payload, sequence: index)
        }
        return TrackingResult(
            status: Self.status(from: result.latestStatusDetail?.derivedCode
                ?? result.latestStatusDetail?.code),
            estimatedDelivery: Self.estimatedDelivery(from: result),
            events: events
        )
    }

    // MARK: - Auth

    private func authToken() async throws -> String {
        // Refresh a minute early so a token can't lapse mid-flight.
        if let token, let tokenExpiry, tokenExpiry > Date.now.addingTimeInterval(60) {
            return token
        }

        var request = URLRequest(url: baseURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: apiSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data = try await perform(request)
        let payload = try decode(TokenResponse.self, from: data)
        guard let accessToken = payload.access_token else { throw CarrierError.unauthorized }

        token = accessToken
        tokenExpiry = Date.now.addingTimeInterval(TimeInterval(payload.expires_in ?? 3600))
        return accessToken
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200..<300: return data
            case 401, 403: throw CarrierError.unauthorized
            case 404: throw CarrierError.notFound
            case 429: throw CarrierError.rateLimited
            default: throw CarrierError.network("FedEx returned status \(http.statusCode).")
            }
        } catch let error as CarrierError {
            throw error
        } catch {
            throw CarrierError.network(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CarrierError.network("FedEx sent data in an unexpected shape.")
        }
    }

    // MARK: - Mapping

    /// FedEx scan codes. `DL` delivered, `OD` on vehicle for delivery, `DE`
    /// delivery exception; the rest of the movement codes read as in transit.
    static func status(from code: String?) -> ParcelStatus {
        switch code?.uppercased() {
        case "DL": .delivered
        case "OD": .outForDelivery
        case "DE", "SE": .exception
        case "IT", "AR", "DP", "AF", "PU", "HP", "OC": .inTransit
        case "PU_PENDING", "SP", "LP": .pending
        case .some(let value) where !value.isEmpty: .inTransit
        default: .unknown
        }
    }

    static func event(_ payload: ScanEvent, sequence: Int = 0) -> TrackingEvent? {
        guard let date = payload.date.flatMap(ISO8601Date.parse) else { return nil }
        let location = [payload.scanLocation?.city, payload.scanLocation?.stateOrProvinceCode]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        return TrackingEvent(
            occurredAt: date,
            detail: payload.eventDescription ?? payload.derivedStatus ?? "Update",
            location: location,
            status: status(from: payload.derivedStatusCode ?? payload.eventType),
            sequence: sequence
        )
    }

    static func estimatedDelivery(from result: TrackResult) -> Date? {
        if let window = result.estimatedDeliveryTimeWindow?.window?.ends.flatMap(ISO8601Date.parse) {
            return window
        }
        let interesting = ["ESTIMATED_DELIVERY", "ACTUAL_DELIVERY"]
        return result.dateAndTimes?
            .first { interesting.contains($0.type ?? "") }?
            .dateTime.flatMap(ISO8601Date.parse)
    }
}

/// FedEx timestamps carry an offset (`2026-05-19T07:36:00+02:00`), and some
/// fields arrive without one, so both are accepted.
enum ISO8601Date {
    // Configured once and only read afterwards, so sharing them is safe.
    nonisolated(unsafe) private static let withOffset: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    nonisolated(unsafe) private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        withOffset.date(from: text) ?? plain.date(from: text) ?? dateOnly.date(from: text)
    }
}

// MARK: - Wire format

private struct TokenResponse: Decodable {
    let access_token: String?
    let expires_in: Int?
}

private struct TrackRequest: Encodable {
    let includeDetailedScans: Bool
    let trackingInfo: [Info]

    struct Info: Encodable {
        let trackingNumberInfo: Number
        struct Number: Encodable { let trackingNumber: String }
    }
}

private struct TrackResponse: Decodable {
    let output: Output?
    struct Output: Decodable {
        let completeTrackResults: [CompleteResult]?
    }
    struct CompleteResult: Decodable {
        let trackResults: [TrackResult]?
    }
}

struct TrackResult: Decodable {
    let latestStatusDetail: StatusDetail?
    let dateAndTimes: [DateAndTime]?
    let scanEvents: [ScanEvent]?
    let estimatedDeliveryTimeWindow: EstimatedWindow?
    let error: TrackError?

    struct StatusDetail: Decodable {
        let code: String?
        let derivedCode: String?
        let description: String?
    }

    struct DateAndTime: Decodable {
        let type: String?
        let dateTime: String?
    }

    struct EstimatedWindow: Decodable {
        let window: Window?
        struct Window: Decodable { let ends: String? }
    }

    struct TrackError: Decodable {
        let code: String?
        let message: String?
    }
}

struct ScanEvent: Decodable {
    let date: String?
    let eventType: String?
    let eventDescription: String?
    let derivedStatusCode: String?
    let derivedStatus: String?
    let scanLocation: Location?

    struct Location: Decodable {
        let city: String?
        let stateOrProvinceCode: String?
    }
}
