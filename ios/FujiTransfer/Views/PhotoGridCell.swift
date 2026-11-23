import SwiftUI
import UIKit
import FujiCore

struct PhotoGridCell: View {
    let photo: FujiPhotoInfo
    let thumbnail: UIImage?
    let isSelected: Bool
    let isImported: Bool
    let onToggleSelect: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(photo.filename.replacingOccurrences(of: ".JPG", with: ""))
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(5)

            VStack {
                HStack(alignment: .top) {
                    if isImported {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                            .accessibilityLabel("Bereits importiert")
                    }
                    Spacer()
                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.92))
                            .shadow(radius: 2)
                            .frame(width: 44, height: 44, alignment: .topTrailing)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Auswahl entfernen" : "Foto auswählen")
                }
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
