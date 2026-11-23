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
            Color.secondary.opacity(0.15)
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
                HStack {
                    if isImported {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(4)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    Spacer()
                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? .blue : .white.opacity(0.9))
                            .shadow(radius: 2)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Auswahl entfernen" : "Foto auswaehlen")
                }
                .padding(6)
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 3)
            }
        }
    }
}
