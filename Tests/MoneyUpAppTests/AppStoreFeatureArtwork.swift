import SwiftUI
import UIKit

/// Store-only composition around an unaltered production-view capture.
/// No fabricated controls, altered amounts, or private ledger screenshots.
struct AppStoreFeatureArtwork<Content: View>: View {
    let title: String
    let subtitle: String
    let chinese: Bool
    var dark = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image("MoneyUpBrandMark").renderingMode(.template).resizable().scaledToFit().frame(width: 17, height: 17)
                    Text(verbatim: "MONEYUP").tracking(3)
                    Spacer()
                    Text(verbatim: chinese ? "私密 · 从容" : "PRIVATE BY DESIGN").tracking(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dark ? Color(red: 0.60, green: 0.85, blue: 0.73) : Color(red: 0.20, green: 0.40, blue: 0.34))
                Text(verbatim: title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(dark ? Color(red: 0.94, green: 0.97, blue: 0.91) : Color(red: 0.08, green: 0.19, blue: 0.16))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(dark ? Color(red: 0.65, green: 0.77, blue: 0.71) : Color(red: 0.29, green: 0.40, blue: 0.36))
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 20)
            content
                .frame(width: 428, height: 926)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(dark ? 0.15 : 0.9), lineWidth: 1))
                .shadow(color: Color(red: 0.1, green: 0.3, blue: 0.2).opacity(0.16), radius: 26, y: 12)
                .scaleEffect(0.78)
                .frame(width: 334, height: 723)
            Spacer(minLength: 8)
            Text(verbatim: chinese ? "示例账本 · 真实应用界面" : "Sample ledger · Real app screens")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(dark ? Color(red: 0.58, green: 0.71, blue: 0.65) : Color(red: 0.35, green: 0.45, blue: 0.4))
                .padding(.bottom, 16)
        }
        .frame(width: 428, height: 926)
        .background {
            LinearGradient(colors: dark
                           ? [Color(red: 0.025, green: 0.065, blue: 0.055), Color(red: 0.075, green: 0.19, blue: 0.14)]
                           : [Color(red: 0.96, green: 0.96, blue: 0.90), Color(red: 0.83, green: 0.92, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

struct AppStoreBrandArtwork: View {
    let chinese: Bool
    let screen: UIImage

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("MoneyUpBrandMark").renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22)
                Text(verbatim: "MONEYUP").tracking(4).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(verbatim: chinese ? "私密记账 · 从容生活" : "PRIVATE MONEY. CALMER DAYS.")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.62, green: 0.84, blue: 0.72))
            .padding(.horizontal, 28).padding(.top, 32)
            Text(verbatim: chinese ? "钱花得明白，\n生活有节拍。" : "Know your flow.\nChoose where to go.")
                .font(.system(size: 42, weight: .bold, design: .rounded)).tracking(-1.5)
                .foregroundStyle(Color(red: 0.94, green: 0.97, blue: 0.90))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 26)
            Image("MoneyUpMoneyWorld")
                .resizable().scaledToFit().frame(width: 360, height: 335)
                .shadow(color: Color.green.opacity(0.12), radius: 36, y: 10)
            Text(verbatim: chinese ? "预算 · 收支 · 储蓄目标" : "BUDGETS · SPENDING · SAVINGS")
                .font(.system(size: 11, weight: .semibold)).tracking(2)
                .foregroundStyle(Color(red: 0.69, green: 0.83, blue: 0.75)).padding(.bottom, 20)
            Image(uiImage: screen).resizable().scaledToFill()
                .frame(width: 346, height: 300, alignment: .top).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12), lineWidth: 1))
            Spacer(minLength: 10)
            Text(verbatim: chinese ? "真实应用界面 · 虚构示例账本" : "Real app screens · A fictional sample ledger")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.48))
                .padding(.bottom, 18)
        }
        .frame(width: 428, height: 926)
        .background {
            RadialGradient(colors: [Color(red: 0.09, green: 0.23, blue: 0.17), Color(red: 0.025, green: 0.055, blue: 0.045)],
                           center: .center, startRadius: 30, endRadius: 520)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}
