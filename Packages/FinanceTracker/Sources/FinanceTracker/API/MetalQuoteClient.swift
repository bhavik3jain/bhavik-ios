import Foundation

/// Gold and silver prices per troy ounce, from the COMEX front-month
/// futures GC=F and SI=F — the tickers the Stocks app shows.
///
/// There's no API into the Stocks app itself. This reads the same quotes from
/// Yahoo Finance's chart endpoint, which is what the Stocks app has long been
/// fed by. It's public and needs no key, but it isn't a documented API: if
/// Yahoo changes it, fetching fails, and every month simply keeps the prices
/// it has (see `MetalPriceFeed`).
public struct MetalQuoteClient: Sendable {
    public static let goldSymbol = "GC=F"
    public static let silverSymbol = "SI=F"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum QuoteError: LocalizedError, Equatable {
        case badResponse(Int)
        case noPrice

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): "The price service answered \(status)."
            case .noPrice: "The price service sent no price."
            }
        }
    }

    public func latestPrices() async throws -> MetalPrices {
        async let gold = price(of: Self.goldSymbol)
        async let silver = price(of: Self.silverSymbol)
        return try await MetalPrices(gold: gold, silver: silver)
    }

    public func price(of symbol: String) async throws -> Double {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/")!
        components.path += symbol
        components.queryItems = [URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "range", value: "1d")]
        let (data, response) = try await session.data(from: components.url!)
        // Yahoo answers 429 to a request with no User-Agent (curl's default);
        // URLSession always sends one, and that is accepted.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuoteError.badResponse(http.statusCode)
        }
        return try Self.parsePrice(data)
    }

    /// `chart.result[0].meta.regularMarketPrice`, the last traded price.
    public static func parsePrice(_ data: Data) throws -> Double {
        let chart = try JSONDecoder().decode(ChartResponse.self, from: data)
        guard let price = chart.chart.result?.first?.meta.regularMarketPrice, price > 0 else {
            throw QuoteError.noPrice
        }
        return price
    }

    private struct ChartResponse: Decodable {
        let chart: Chart

        struct Chart: Decodable {
            let result: [Result]?
        }

        struct Result: Decodable {
            let meta: Meta
        }

        struct Meta: Decodable {
            let regularMarketPrice: Double?
        }
    }
}
