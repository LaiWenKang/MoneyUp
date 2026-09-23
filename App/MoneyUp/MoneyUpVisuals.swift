import SwiftUI
import MoneyUpCore

enum MoneyUpIllustrationRole {
    case onboarding
    case hero
    case empty
    case inline

    var height: CGFloat {
        switch self {
        case .onboarding: 148
        case .hero: 92
        case .empty: 116
        case .inline: 72
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .onboarding: 240
        case .hero: 116
        case .empty: 190
        case .inline: 90
        }
    }
}

/// Shared pace semantics prevent Today and Plan from describing the same
/// financial state differently. Spending against a zero limit is explicitly
/// over plan (ratio 2), never the merely-full ratio 1.
func moneyUpPaceRatio(
    spent: Decimal,
    limit: Decimal,
    operation: String
) -> DerivedValue<Double> {
    guard limit >= .zero else {
        DerivedValueDiagnostics.record(
            .amountCalculationFailed,
            operation: operation
        )
        return .unavailable(.amountCalculationFailed)
    }
    guard limit > .zero else {
        return .available(spent > .zero ? 2 : 0)
    }
    do {
        return .available(
            NSDecimalNumber(
                decimal: try CheckedDecimal.ratio(spent, limit)
            ).doubleValue
        )
    } catch {
        DerivedValueDiagnostics.record(
            .amountCalculationFailed,
            operation: operation,
            error: error
        )
        return .unavailable(.amountCalculationFailed)
    }
}

/// Generated 3D artwork is decorative only. Financial quantities remain in
/// native text and flat, measurable 2D graphics elsewhere in the interface.
/// Role-based sizing prevents decorative art from consuming the space needed
/// for the screen's decision and primary action.
struct MoneyUpIllustration: View {
    @Environment(\.moneyUpShowsIllustrations) private var showsIllustrations
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let assetName: String
    let role: MoneyUpIllustrationRole

    init(_ assetName: String, role: MoneyUpIllustrationRole = .empty) {
        self.assetName = assetName
        self.role = role
    }

    @ViewBuilder
    var body: some View {
        if showsIllustrations && !(dynamicTypeSize.isAccessibilitySize && role == .inline) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: role.maximumWidth,
                    height: dynamicTypeSize.isAccessibilitySize
                        ? min(role.height, 84)
                        : role.height
                )
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Spending versus limit with the elapsed-month marker used across Today,
/// Plan, and the simulator. Overspend gets a warning glyph as well as color.
struct MoneyUpPaceBar: View {
    @Environment(\.moneyUpReduceMotion) private var reduceMotion
    let ratio: Double
    let elapsed: Double
    var announcesStatus = true

    private var status: MoneyUpPaceStatus {
        MoneyUpPaceStatus(ratio: ratio, elapsed: elapsed)
    }

    private var statusKey: LocalizedStringKey {
        switch status {
        case .over: "dashboard.budget_pace.over"
        case .ahead: "dashboard.budget_pace.ahead"
        case .within: "dashboard.budget_pace.within"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clampedRatio = min(max(ratio, 0), 1)
            let clampedElapsed = min(max(elapsed, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))

                // The fill passing the month marker is the signal; the tint
                // only reinforces it (and the status chip names it).
                Capsule()
                    .fill(status.tint)
                    .frame(width: width * clampedRatio)

                Rectangle()
                    .fill(Color.primary.opacity(0.60))
                    .frame(width: 2, height: 14)
                    .offset(x: width * clampedElapsed - 1)

                if ratio > 1 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.moneyUpBackground, Color.moneyUpDanger)
                        .frame(width: 16, height: 16)
                        .background(Color.moneyUpSurfaceElevated, in: Circle())
                        .offset(x: max(0, width - 16))
                }
            }
        }
        .frame(height: 14)
        // After a save elsewhere, the fill moves to its new length so the eye
        // sees what the entry did; the amounts beside it are never delayed.
        .animation(MoneyUpMotion.animation(for: .stateChange, reduceMotion: reduceMotion), value: ratio)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusKey)
        .accessibilityValue(String(format: AppLocalization.string("dashboard.budget_pace.accessibility"),
            ratio.formatted(.percent.precision(.fractionLength(0))),
            elapsed.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityHidden(!announcesStatus)
    }
}

/// One reading of spending against the calendar, shared by the bar tint and
/// the status chip so Today and Plan never disagree about "on pace".
enum MoneyUpPaceStatus: Equatable {
    case within
    case ahead
    case over

    init(ratio: Double, elapsed: Double) {
        if ratio > 1 { self = .over }
        else if ratio > elapsed + 0.05 { self = .ahead }
        else { self = .within }
    }

    var tint: Color {
        switch self {
        case .within: .moneyUpPositive
        case .ahead: .moneyUpWarning
        case .over: .moneyUpDanger
        }
    }

    var systemImage: String {
        switch self {
        case .within: "checkmark.circle.fill"
        case .ahead: "hare.fill"
        case .over: "exclamationmark.circle.fill"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .within: "plan.pace.within"
        case .ahead: "plan.pace.ahead"
        case .over: "plan.pace.over"
        }
    }
}

/// A glyph-and-word verdict on the pace bar above it, so nobody has to decode
/// the month marker to learn whether they are on track.
struct MoneyUpPaceStatusChip: View {
    let status: MoneyUpPaceStatus

    var body: some View {
        Label(status.titleKey, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.12), in: Capsule())
    }
}

/// A compact, exact composition diagram for the Today position headline.
/// The figure remains immediate text; this orbit adds a glanceable cash/debt
/// relationship without inventing a consolidated currency or another label.
struct MoneyUpPositionOrbit: View {
    let cashAmount: Decimal
    let debtAmount: Decimal

    private var cashShare: DerivedValue<Double?> {
        do {
            let cash = abs(cashAmount)
            let debt = abs(debtAmount)
            let total = try CheckedDecimal.adding(cash, debt)
            guard total > .zero else { return .available(nil) }
            return .available(
                NSDecimalNumber(
                    decimal: try CheckedDecimal.ratio(cash, total)
                ).doubleValue
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "position-orbit-ratio",
                error: error
            )
            return .unavailable(.amountCalculationFailed)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 6)

            if case let .available(.some(value)) = cashShare {
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(
                        AngularGradient(
                            colors: [Color.accentColor.opacity(0.64), .accentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Circle()
                    .trim(from: min(max(value + 0.025, 0), 1), to: 1)
                    .stroke(
                        Color.moneyUpWarning.opacity(0.86),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Image(systemName: "scale.3d")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

/// The monthly budget headline uses the same visual grammar as its detailed
/// pace bar: the arc is spending/limit and the small marker is elapsed month.
/// Overspend retains a warning glyph, so status is never color-only.
struct MoneyUpBudgetOrbit: View {
    let ratio: Double
    let elapsed: Double

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = max(0, size / 2 - 3)
            let clampedRatio = min(max(ratio, 0), 1)
            let clampedElapsed = min(max(elapsed, 0), 1)

            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: clampedRatio)
                    .stroke(
                        ratio > 1
                            ? Color.moneyUpDanger
                            : Color.accentColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(Color.primary)
                    .frame(width: 5, height: 5)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(clampedElapsed * 360))

                Text(ratio.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(ratio > 1 ? Color.moneyUpDanger : Color.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }
}

struct MoneyUpPositionDiagram: View {
    let cashAmount: Decimal
    let debtAmount: Decimal

    private var scale: Decimal {
        max(max(abs(cashAmount), abs(debtAmount)), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            positionBar(
                amount: cashAmount,
                symbol: "banknote.fill",
                color: .accentColor
            )
            positionBar(
                amount: debtAmount,
                symbol: "creditcard.fill",
                color: Color.moneyUpWarning
            )
        }
        .accessibilityHidden(true)
    }

    private func positionBar(
        amount: Decimal,
        symbol: String,
        color: Color
    ) -> some View {
        let fraction: DerivedValue<Double>
        do {
            fraction = .available(
                NSDecimalNumber(
                    decimal: try CheckedDecimal.ratio(abs(amount), scale)
                ).doubleValue
            )
        } catch {
            DerivedValueDiagnostics.record(
                .amountCalculationFailed,
                operation: "position-diagram-ratio",
                error: error
            )
            fraction = .unavailable(.amountCalculationFailed)
        }

        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24)

            switch fraction {
            case let .available(value):
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(color.opacity(0.78))
                            .frame(width: proxy.size.width * min(max(value, 0), 1))
                    }
                }
                .frame(height: 10)
            case let .unavailable(issue):
                DerivedValueUnavailableView(issue: issue)
            }
        }
    }
}

struct MoneyUpSymbolBadge: View {
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 1)
                .padding(7)
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// One recognisable glyph per category, so a row, a pinned budget, or a plan
/// line can be found by shape before its name is read. The name always stays
/// visible beside it; the glyph is recognition, never the only label.
///
/// Resolution is deterministic and local: a catalogue preset's own symbol,
/// then a keyword in the category's name (English or Chinese), then the
/// nearest ancestor's glyph, then a neutral tag.
enum MoneyUpCategorySymbol {
    static let fallbackExpense = "tag.fill"
    static let fallbackIncome = "tray.and.arrow.down.fill"

    static func symbol(
        for categoryID: UUID,
        accountsByID: [UUID: LedgerAccount]
    ) -> String {
        var visited: Set<UUID> = []
        var cursor = accountsByID[categoryID]
        let kind = cursor?.kind
        while let account = cursor, visited.insert(account.id).inserted {
            if let presetID = account.presetID,
               let preset = LedgerPresetCatalog.preset(id: presetID) {
                return preset.symbol
            }
            if let symbol = symbol(forName: account.name) { return symbol }
            cursor = account.parentID.flatMap { accountsByID[$0] }
        }
        return kind == .income ? fallbackIncome : fallbackExpense
    }

    /// The earliest keyword in the name wins ("Food & coffee" is food), and
    /// the table order breaks ties, so specific entries ("personal care")
    /// sit above broad ones.
    static func symbol(forName name: String) -> String? {
        let lowered = name.lowercased()
        var words: [(offset: Int, word: String)] = []
        var current = ""
        var currentStart = 0
        for (offset, character) in lowered.enumerated() {
            if character.isLetter || character.isNumber {
                if current.isEmpty { currentStart = offset }
                current.append(character)
            } else if !current.isEmpty {
                words.append((currentStart, current))
                current = ""
            }
        }
        if !current.isEmpty { words.append((currentStart, current)) }

        var best: (offset: Int, symbol: String)?
        for (keywords, symbol) in keywordTable {
            for keyword in keywords {
                let offset: Int?
                if keyword.contains(" ")
                    || keyword.unicodeScalars.contains(where: { $0.value > 0x2E7F }) {
                    offset = lowered.range(of: keyword).map {
                        lowered.distance(from: lowered.startIndex, to: $0.lowerBound)
                    }
                } else {
                    // Short keywords ("tea", "bus", "pet") must be whole
                    // words so "petty cash" or "category" never match.
                    offset = words.first {
                        $0.word == keyword || (keyword.count >= 4 && $0.word.hasPrefix(keyword))
                    }?.offset
                }
                if let offset, offset < (best?.offset ?? .max) {
                    best = (offset, symbol)
                }
            }
        }
        return best?.symbol
    }

    private static let keywordTable: [([String], String)] = [
        (["salary", "wage", "payroll", "paycheck", "工资", "薪"], "briefcase.fill"),
        (["bonus", "奖金"], "star.fill"),
        (["dividend", "invest", "投资", "股息", "理财"], "chart.line.uptrend.xyaxis"),
        (["refund", "rebate", "cashback", "退款", "返现"], "arrow.uturn.backward"),
        (["personal care", "beauty", "hair", "salon", "美容", "护理", "理发"], "sparkles"),
        (["coffee", "cafe", "café", "tea", "咖啡", "奶茶", "茶"], "cup.and.saucer.fill"),
        (["grocer", "supermarket", "超市", "买菜", "生鲜"], "basket.fill"),
        (["food", "dining", "restaurant", "meal", "lunch", "dinner", "breakfast", "snack",
          "餐", "饭", "吃", "外卖"], "fork.knife"),
        (["fuel", "petrol", "gasoline", "加油", "油费"], "fuelpump.fill"),
        (["parking", "停车"], "parkingsign.circle.fill"),
        (["taxi", "grab", "uber", "rideshare", "打车", "出租"], "car.fill"),
        (["transport", "transit", "commute", "bus", "train", "metro", "mrt", "subway",
          "交通", "地铁", "公交", "通勤"], "bus.fill"),
        (["vehicle", "auto", "汽车", "车"], "car.fill"),
        (["rent", "mortgage", "housing", "home", "house", "房", "居住", "住房"], "house.fill"),
        (["internet", "wifi", "broadband", "网费", "宽带"], "wifi"),
        (["phone", "mobile", "话费", "手机"], "iphone"),
        (["utilit", "electric", "power", "water", "gas", "水电", "电费", "水费", "燃气"], "bolt.fill"),
        (["subscri", "streaming", "订阅", "会员"], "repeat.circle.fill"),
        (["cloth", "apparel", "fashion", "shoe", "衣", "鞋", "服装"], "tshirt.fill"),
        (["electronic", "gadget", "computer", "数码", "电子"], "laptopcomputer"),
        (["shop", "购物", "网购"], "bag.fill"),
        (["entertain", "leisure", "cinema", "movie", "film", "game", "games",
          "娱乐", "电影", "休闲", "游戏"], "film.fill"),
        (["travel", "trip", "flight", "hotel", "holiday", "vacation",
          "旅行", "旅游", "机票", "酒店"], "airplane"),
        (["dental", "dentist", "牙"], "cross.case"),
        (["health", "medical", "doctor", "clinic", "pharmacy", "medicine",
          "医", "药", "健康"], "cross.case.fill"),
        (["insur", "保险"], "shield.fill"),
        (["fitness", "gym", "sport", "workout", "健身", "运动"], "figure.walk"),
        (["educat", "school", "tuition", "course", "教育", "学费", "培训"], "graduationcap.fill"),
        (["book", "书"], "books.vertical.fill"),
        (["child", "kid", "kids", "baby", "孩", "儿童", "育儿"], "figure.and.child.holdinghands"),
        (["pets", "pet", "dog", "dogs", "cat", "cats", "宠物"], "pawprint.fill"),
        (["gift", "礼"], "gift.fill"),
        (["donat", "charity", "捐", "慈善"], "heart.fill"),
        (["tax", "taxes", "税"], "doc.text.fill"),
        (["interest", "利息"], "percent"),
        (["fee", "fees", "charge", "手续费", "费用"], "doc.plaintext"),
        (["essential", "everyday", "daily", "household", "日常", "必需", "家居", "日用"], "cart.fill"),
        (["lifestyle", "生活"], "sparkles"),
        (["other", "misc", "其他", "杂项"], "ellipsis.circle")
    ]

    /// A stable palette slot per category so the same category keeps the same
    /// tint on every screen. Colour only reinforces the glyph and name.
    static func tint(for categoryID: UUID) -> Color {
        let hash = categoryID.uuidString.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) & 0xFFFF
        }
        return MoneyUpChartPalette.color(at: hash % MoneyUpChartPalette.ordered.count)
    }
}

/// The circular glyph that fronts a category or transaction row. An optional
/// corner mark carries the movement (income, refund) without a second label.
struct MoneyUpCategoryBadge: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 34
    var cornerSymbol: String?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(colorSchemeContrast == .increased ? 0.20 : 0.13),
                in: Circle()
            )
            .overlay(alignment: .bottomTrailing) {
                if let cornerSymbol {
                    Image(systemName: cornerSymbol)
                        .font(.system(size: size * 0.24, weight: .heavy))
                        .foregroundStyle(Color.moneyUpSurfaceElevated)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(tint, in: Circle())
                        .overlay(Circle().stroke(Color.moneyUpSurfaceElevated, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}
