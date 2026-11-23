import SwiftUI
import UIKit
import FujiCore

/// Vollbildvorschau mit schnellem Nachladen der hochaufloesenden Vorschau,
/// Pinch-/Doppeltipp-Zoom, Blaettern (Wischen) und direktem Original-Import.
struct PhotoPreviewView: View {
    let store: CameraSessionStore
    @State private var currentHandle: UInt32
    @Environment(\.dismiss) private var dismiss

    init(store: CameraSessionStore, initialPhoto: FujiPhotoInfo) {
        self.store = store
        self._currentHandle = State(initialValue: initialPhoto.handle)
    }

    private var currentPhoto: FujiPhotoInfo? {
        store.photos.first { $0.handle == currentHandle }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentHandle) {
                ForEach(store.photos) { photo in
                    ZoomablePhotoPage(
                        image: store.previewImages[photo.handle] ?? store.thumbnails[photo.handle],
                        isLoadingHighRes: store.isLoadingPreviewHandle == photo.handle
                    )
                    .tag(photo.handle)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if let photo = currentPhoto {
                    bottomBar(photo: photo)
                }
            }
        }
        .statusBarHidden(false)
        .task(id: currentHandle) {
            if let photo = currentPhoto {
                await store.loadPreviewImage(for: photo)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Vorschau schliessen")

            Spacer()

            if let photo = currentPhoto {
                VStack(spacing: 2) {
                    Text(photo.filename)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(.white)
                    Text("\(photo.width) × \(photo.height) · \(formattedDate(photo.dateCreated))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            }

            Spacer()

            if let photo = currentPhoto {
                let isSelected = store.selectedHandles.contains(photo.handle)
                Button {
                    store.toggleSelection(photo.handle)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .blue : .white)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(isSelected ? "Auswahl entfernen" : "Foto auswaehlen")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func bottomBar(photo: FujiPhotoInfo) -> some View {
        HStack(spacing: 12) {
            if store.importedFilenames.contains(photo.filename) {
                Label("Bereits in Fotos", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.65), in: Capsule())
            }

            Spacer()

            Button {
                Task { await store.downloadSinglePhoto(photo) }
            } label: {
                Label("Original in Fotos laden", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.transferState != nil)
        }
        .padding()
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func formattedDate(_ raw: String) -> String {
        // Fujifilm PTP Datum: "20261022T101638"
        guard raw.count >= 15 else { return raw }
        let y = raw.prefix(4)
        let m = raw.dropFirst(4).prefix(2)
        let d = raw.dropFirst(6).prefix(2)
        let h = raw.dropFirst(9).prefix(2)
        let min = raw.dropFirst(11).prefix(2)
        return "\(d).\(m).\(y), \(h):\(min)"
    }
}

/// Einzelne zoombare Seite (Pinch-to-Zoom + Doppeltipp 1x <-> 2.5x).
private struct ZoomablePhotoPage: View {
    let image: UIImage?
    let isLoadingHighRes: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(1.0, lastScale * value), 4.0)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            if scale > 1.1 {
                                scale = 1.0
                                lastScale = 1.0
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }

            if isLoadingHighRes {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text("Lade scharfe Vorschau...")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 84)
                }
            }
        }
    }
}
