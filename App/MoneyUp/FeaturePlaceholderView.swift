import SwiftUI

struct FeaturePlaceholderView: View {
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text(detailKey)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(titleKey)
        }
    }
}
