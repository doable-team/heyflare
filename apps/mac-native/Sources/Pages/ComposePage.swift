import SwiftUI

/// `/compose` (`pages/Compose.tsx`): the composer in the page under a "New message" title,
/// prefilled from `?to=&subject=`, with the caret in the body when a recipient came along.
struct ComposePage: View {
    var to: String = ""
    var subject: String = ""

    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var model: ComposerModel?

    var body: some View {
        PageColumn(width: 672) {
            Text("New message")
                .font(W.font(28, 700))
                .tracking(-0.56)
                .foregroundStyle(W.foreground)
                .webLine(28, weight: 700)
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            if let model {
                ComposerView(model: model, inline: true, autoFocusBody: !to.isEmpty)
                    .background(W.background)
                    .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                    .rounded(W.radiusLg)
            }
        }
        .cardScrollKeys(enabled: ui.region == .content)
        .onAppear {
            guard model == nil else { return }
            let m = ComposerModel(initial: ComposerInitial(to: AddressInput<EmptyView>.parse(to), subject: subject))
            m.onDone = { router.back() }
            m.onCancel = { router.back() }
            Compose.current = m
            model = m
        }
        .onDisappear { if Compose.current === model { Compose.current = nil } }
    }
}
