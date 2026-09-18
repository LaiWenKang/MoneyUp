import SwiftUI

/// Store-only composition around an unaltered production-view capture.
/// No fabricated controls, altered amounts, or private ledger screenshots.
struct AppStoreFeatureArtwork<Content: View>: View {
    let title: String
    let subtitle: String
    let chinese: Bool
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
                .foregroundStyle(Color(red: 0.20, green: 0.40, blue: 0.34))
                Text(verbatim: title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(Color(red: 0.08, green: 0.19, blue: 0.16))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.29, green: 0.40, blue: 0.36))
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 20)
            content
                .frame(width: 428, height: 926)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.9), lineWidth: 1))
                .shadow(color: Color(red: 0.1, green: 0.3, blue: 0.2).opacity(0.16), radius: 26, y: 12)
                .scaleEffect(0.78)
                .frame(width: 334, height: 723)
            Spacer(minLength: 8)
            Text(verbatim: chinese ? "示例账本 · 真实应用界面" : "Sample ledger · Real app screens")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 0.35, green: 0.45, blue: 0.4))
                .padding(.bottom, 16)
        }
        .frame(width: 428, height: 926)
        .background {
            LinearGradient(colors: [Color(red: 0.96, green: 0.96, blue: 0.90),
                                    Color(red: 0.83, green: 0.92, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
