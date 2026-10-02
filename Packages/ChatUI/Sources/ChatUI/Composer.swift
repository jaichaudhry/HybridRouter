import RouterKit
import SwiftUI

/// Text field, route override menu and send button.
struct Composer: View {
    @Bindable var model: ChatModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            routeMenu
            TextField("Message", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var routeMenu: some View {
        Menu {
            Picker("Route", selection: $model.routeOverride) {
                Label("Auto", systemImage: "wand.and.stars").tag(Route?.none)
                ForEach(Route.allCases, id: \.self) { route in
                    Label(route.displayName, systemImage: route.symbolName).tag(Route?.some(route))
                }
            }
        } label: {
            Image(systemName: model.routeOverride?.symbolName ?? "wand.and.stars")
                .font(.title2)
                .foregroundStyle(model.routeOverride?.tint ?? .secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Route: \(model.routeOverride?.displayName ?? "Auto")")
    }

    private func send() {
        guard model.canSend else { return }
        Task { await model.send() }
    }
}
