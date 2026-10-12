import PhotosUI
import HybridRouterKit
import SwiftUI
import UniformTypeIdentifiers

/// The floating composer, laid out like other chat apps: one "+" menu holds attachments and
/// the route choice, so the message field gets the width. Private stays one tap away inside
/// the field. A pinned route shows as a removable chip above, and Send (the only tinted
/// control) takes the route's color.
struct Composer: View {
    @Bindable var model: ChatModel

    @State private var photoSelection: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var showsScanner = false
    @State private var attachError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 6) {
            if let route = model.routeOverride {
                pinnedRouteChip(route)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }
            if !model.attachments.isEmpty {
                attachmentChips
            }
            if let attachError {
                Text(attachError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            GlassEffectContainer(spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    // Large text: give the message field its own full-width row.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .bottom, spacing: 8) {
                            fieldWithPrivate
                            sendButton
                        }
                        optionsMenu
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        optionsMenu
                        fieldWithPrivate
                        sendButton
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(Motion.badge, value: model.isPrivate)
        .animation(Motion.badge, value: model.routeOverride)
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            photoSelection = nil
            Task { await addPhoto(item) }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.plainText, .pdf]) { result in
            addDocument(result)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsScanner) {
            DocumentScanner { pages in
                for (index, page) in pages.enumerated() {
                    model.attachments.append(.scan(page, name: "Scan \(index + 1)"))
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// The message field with the Private lock at its trailing edge, in one glass shape.
    private var fieldWithPrivate: some View {
        HStack(alignment: .bottom, spacing: 0) {
            messageField
            privateToggle
        }
        // Not .interactive(): interactive glass takes touches even where the "+" menu sits
        // over it, which made the menu's bottom row (Photo) untappable.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var messageField: some View {
        TextField(model.isPrivate ? "Private message" : "Message", text: $model.draft, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(.leading, 14)
            .padding(.vertical, 11)
            // A vertical text field doesn't submit on Return, so handle hardware keyboards here.
            // Shift-Return still adds a new line.
            .onKeyPress(.return, phases: .down) { press in
                guard !press.modifiers.contains(.shift) else { return .ignored }
                send()
                return .handled
            }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.labelOnFill)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(sendTint)
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
    }

    /// Attachments and the route choice. The route lives in a submenu that shows its current
    /// value, since most messages stay on Auto.
    private var optionsMenu: some View {
        Menu {
            Section {
                Button("Photo", systemImage: "photo") { showsPhotoPicker = true }
                #if os(iOS)
                if DocumentScanner.isSupported {
                    Button("Scan document", systemImage: "doc.viewfinder") { showsScanner = true }
                }
                #endif
                Button("Text or PDF file", systemImage: "doc.text") { showsFileImporter = true }
            }
            Section {
                Picker(selection: $model.routeOverride) {
                    Label("Auto", systemImage: "arrow.triangle.branch").tag(Route?.none)
                    ForEach(Route.allCases, id: \.self) { route in
                        Label(route.displayName, systemImage: route.symbolName).tag(Route?.some(route))
                    }
                } label: {
                    Label("Route", systemImage: "arrow.triangle.branch")
                    Text(model.routeOverride?.displayName ?? "Auto")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Attach or choose route")
        .accessibilityValue("Route: \(model.routeOverride?.displayName ?? "Auto")")
    }

    /// A pinned route, shown only when it isn't Auto. Tap to go back to Auto.
    private func pinnedRouteChip(_ route: Route) -> some View {
        Button {
            model.routeOverride = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: route.symbolName)
                Text("Always \(route.displayName)")
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(route.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .routeCapsule(route)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Route pinned to \(route.displayName)")
        .accessibilityHint("Double-tap to go back to Auto")
    }

    private var privateToggle: some View {
        Button {
            model.isPrivate.toggle()
        } label: {
            Image(systemName: model.isPrivate ? "lock.fill" : "lock.open")
                .font(.body.weight(.medium))
                .foregroundStyle(model.isPrivate ? Route.onDevice.ink : .primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: model.isPrivate)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isPrivate)
        .accessibilityLabel("Private")
        .accessibilityValue(model.isPrivate ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Private messages never go to Claude")
    }

    private var attachmentChips: some View {
        AttachmentTray(attachments: model.attachments) { attachment in
            model.attachments.removeAll { $0.id == attachment.id }
        }
    }

    private func addPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let attachment = ChatAttachment.image(data: data, name: "Photo \(model.attachments.count + 1)") else {
            showAttachError("Couldn't read that photo.")
            return
        }
        attachError = nil
        model.attachments.append(attachment)
        AccessibilityNotification.Announcement("Added \(attachment.name)").post()
    }

    private func addDocument(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let attachment = try ChatAttachment.document(url: url)
            model.attachments.append(attachment)
            attachError = nil
            AccessibilityNotification.Announcement("Added \(attachment.name)").post()
        } catch let error as ChatAttachment.DocumentError {
            showAttachError(error.localizedDescription)
        } catch {
            showAttachError("Couldn't read that file.")
        }
    }

    private func showAttachError(_ message: String) {
        attachError = message
        AccessibilityNotification.Announcement(message).post()
    }

    /// The pinned route's fill, On-device teal while Private is on, or neutral ink on Auto.
    private var sendTint: Color {
        if let route = model.routeOverride { return route.fill }
        return model.isPrivate ? Route.onDevice.fill : Theme.ink
    }

    private func send() {
        guard model.canSend else { return }
        let sent = model.draft
        Task { await model.send() }
        // Tapping Send while the keyboard shows suggestions can make it commit the pending
        // autocorrection just after the field was cleared, putting the sent text back.
        // Clear it again once that's happened, unless the reply already finished (a
        // failed send hands the draft back on purpose).
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            // The restored text may differ in its last word (the correction itself).
            let restored = model.draft.commonPrefix(with: sent).count >= sent.count / 2
            if model.isSending, !sent.isEmpty, !model.draft.isEmpty, restored {
                model.draft = ""
            }
        }
    }
}
