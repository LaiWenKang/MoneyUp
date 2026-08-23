import Foundation

public enum InvestmentHoldingError: Error, Equatable, Sendable {
    case quantityCannotBeNegative
    case priceCannotBeNegative
}

public struct InvestmentHolding: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var accountID: UUID
    public var symbol: String
    public var name: String
    public var quantity: Decimal
    public var price: Money?
    public var priceAsOf: Date?

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        symbol: String,
        name: String,
        quantity: Decimal,
        price: Money? = nil,
        priceAsOf: Date? = nil
    ) throws {
        guard quantity >= .zero else {
            throw InvestmentHoldingError.quantityCannotBeNegative
        }
        if let price, price.amount < .zero {
            throw InvestmentHoldingError.priceCannotBeNegative
        }

        self.id = id
        self.accountID = accountID
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.price = price
        self.priceAsOf = priceAsOf
    }

    public func marketValue() throws -> Money? {
        guard let price else { return nil }
        return try Money(quantity * price.amount, currency: price.currency)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case symbol
        case name
        case quantity
        case price
        case priceAsOf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                accountID: container.decode(UUID.self, forKey: .accountID),
                symbol: container.decode(String.self, forKey: .symbol),
                name: container.decode(String.self, forKey: .name),
                quantity: container.decode(Decimal.self, forKey: .quantity),
                price: container.decodeIfPresent(Money.self, forKey: .price),
                priceAsOf: container.decodeIfPresent(Date.self, forKey: .priceAsOf)
            )
        } catch let error as InvestmentHoldingError {
            throw DecodingError.dataCorruptedError(
                forKey: .quantity,
                in: container,
                debugDescription: "Invalid investment holding: \(error)"
            )
        }
    }
}
