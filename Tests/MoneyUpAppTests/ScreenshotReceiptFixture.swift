import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fictional payment screenshots: no user's financial data or copied bank UI.
enum ScreenshotReceiptFixture {
    enum Style: String, CaseIterable { case englishLight, englishDark, chinese, itemized }

    static func png(style: Style, currency: String = "SGD") throws -> Data {
        let width = 1170, height = 1800
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.render }
        let dark = style == .englishDark
        context.setFillColor(CGColor(gray: dark ? 0.06 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ink = CGColor(gray: dark ? 0.96 : 0.08, alpha: 1)
        let chinese = style == .chinese
        let rows: [(String, CGFloat)]
        switch style {
        case .englishLight, .englishDark:
            rows = [("PAYMENT SUCCESSFUL", 50), ("Amount paid", 42), (currency + " 12.34", 100),
                ("Paid to: HARBOUR CAFE", 45), ("Payment date: 07/09/2026 09:42", 38),
                ("Available balance: " + currency + " 9876.54", 34), ("Reference: 4829103756", 32)]
        case .chinese:
            rows = [("支付成功", 60), ("实付 " + currency + " 23.45", 90),
                ("商户：星河餐厅", 48), ("交易日期：2026年9月7日 09:42", 40),
                ("账户余额 " + currency + " 9876.54", 36), ("交易编号：4829103756", 32)]
        case .itemized:
            rows = [("HARBOUR GROCERY", 58), ("ORDER RECEIPT", 38),
                ("Subtotal " + currency + " 40.00", 46), ("Delivery " + currency + " 3.00", 46),
                ("Discount " + currency + " 5.00", 46), ("Grand total " + currency + " 38.00", 75),
                ("Payment date: 07/09/2026 09:42", 38), ("Order ID 4829103756", 32)]
        }
        for (index, row) in rows.enumerated() {
            let font = CTFontCreateWithName((chinese ? "PingFangSC-Regular" : "Helvetica") as CFString, row.1, nil)
            let text = NSAttributedString(string: row.0, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
            ])
            context.textPosition = CGPoint(x: 70, y: height - 170 - index * 180)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        guard let image = context.makeImage() else { throw FixtureError.render }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.render
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.render }
        return data as Data
    }

    enum FixtureError: Error { case render }
}
