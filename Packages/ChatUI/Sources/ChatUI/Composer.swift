import PhotosUI
import RouterKit
import SwiftUI
import UniformTypeIdentifiers

/// Text field, attachments, Private toggle, route override menu and send button.
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
            if !model.attachments.isEmpty {
                attachmentChips
            }
            if let attachError {
                Text(attachError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: give the message field its own full-width row.
                HStack(alignment: .bottom, spacing: 8) {
                    messageField
                    sendButton
                }
                HStack(spacing: 8) {
                    attachMenu
                    routeMenu
                    privateToggle
                    Spacer()
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    routeMenu
                    messageField
                    privateToggle
                    sendButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    private var messageField: some View {
        TextField("Message", text: $model.draft, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: .rect(cornerRadius: 18))
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
            Image(systemName: "arrow.up.circle.fill")
                .font(.title)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo", systemImage: "photo") { showsPhotoPicker = true }
            #if os(iOS)
            if DocumentScanner.isSupported {
                Button("Scan document", systemImage: "doc.viewfinder") { showsScanner = true }
            }
            #endif
            Button("Text or PDF file", systemImage: "doc.text") { showsFileImporter = true }
        } label: {
            Image(systemName: "paperclip")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Attach")
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
                .contentShape(.rect)
        }
        .accessibilityLabel("Route")
        .accessibilityValue(model.routeOverride?.displayName ?? "Auto")
    }

    private var privateToggle: some View {
        Button {
            model.isPrivate.toggle()
        } label: {
            Image(systemName: model.isPrivate ? "lock.fill" : "lock.open")
                .font(.title3)
                .foregroundStyle(model.isPrivate ? Color.accentColor : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Private")
        .accessibilityValue(model.isPrivate ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Private messages never go to Claude")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: attachment.image == nil ? "doc.text" : (attachment.isScan ? "doc.viewfinder" : "photo"))
                        Text(attachment.name)
                            .lineLimit(1)
                        Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill") {
                            model.attachments.removeAll { $0.id == attachment.id }
                        }
                        .labelStyle(.iconOnly)
                        // A 44pt target without making the chip bigger.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                        .padding(.vertical, -12)
                        .padding(.trailing, -8)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary, in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
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

    private func send() {
        guard model.canSend else { return }
        Task { await model.send() }
    }
}
