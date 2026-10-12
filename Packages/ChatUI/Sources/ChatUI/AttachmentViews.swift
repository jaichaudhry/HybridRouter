import CoreGraphics
import SwiftUI

/// The composer's attachment tray: photo thumbnails and file cards, each with a remove button.
struct AttachmentTray: View {
    let attachments: [ChatAttachment]
    let onRemove: (ChatAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentTile(name: attachment.name, thumbnail: attachment.thumbnail, isScan: attachment.isScan, size: 64)
                        .overlay(alignment: .topTrailing) {
                            removeButton(for: attachment)
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            // Room for the remove buttons, which sit over each tile's corner.
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .scrollIndicators(.hidden)
        .animation(Motion.card, value: attachments.map(\.id))
    }

    private func removeButton(for attachment: ChatAttachment) -> some View {
        Button {
            onRemove(attachment)
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.labelOnFill)
                .frame(width: 22, height: 22)
                .background(Theme.ink, in: .circle)
                .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                // A 44pt target without a bigger badge.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(x: 14, y: -14)
        .accessibilityLabel("Remove \(attachment.name)")
    }
}

/// A sent message's attachments, shown above its bubble.
struct SentAttachments: View {
    let attachments: [AttachmentPreview]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentTile(name: attachment.name, thumbnail: attachment.thumbnail, isScan: attachment.isScan, size: attachments.count == 1 ? 160 : 96)
            }
        }
    }
}

/// A photo thumbnail, or a card with a file icon and name for documents.
struct AttachmentTile: View {
    let name: String
    let thumbnail: CGImage?
    let isScan: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size > 100 ? 18 : 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size > 100 ? 18 : 14, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: 200, minHeight: 64)
                .background(Theme.card, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thumbnail == nil ? "File: \(name)" : (isScan ? "Scan: \(name)" : "Photo: \(name)"))
    }
}
