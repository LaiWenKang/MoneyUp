import SwiftUI

struct DisplayPreferenceFailurePresenter: View {
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.displayPreferenceFailure != nil, initial: true) { _, failed in
                guard failed, let error = model.displayPreferenceFailure else { return }
                errorMessage = safeUserMessage(for: error, context: .save)
                model.displayPreferenceFailure = nil
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
    }
}
