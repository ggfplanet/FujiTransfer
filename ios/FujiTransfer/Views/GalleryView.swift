import SwiftUI
import FujiCore

struct GalleryView: View {
    let store: CameraSessionStore
    @State private var previewPhoto: FujiPhotoInfo?

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ConnectionModeBadge(
                    style: .wifiActive(label: "WLAN · \(store.sessionInfo?.cameraName ?? "X-T4")")
                )
                Spacer()
                Text("\(store.filteredPhotos.count) sichtbar / \(store.sessionInfo?.totalObjectCount ?? 0) gesamt")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if let info = store.sessionInfo, info.cards.count > 1 {
                slotPicker(info: info)
            }

            GalleryFilterBar(store: store)
                .padding(.bottom, 4)

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            ScrollView {
                if store.filteredPhotos.isEmpty && !store.isLoadingMorePhotos && !store.isApplyingFilter {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(store.galleryFilter.hasActiveFilter
                             ? "Keine Fotos fuer diesen Filter gefunden."
                             : "Keine Fotos auf dieser Speicherkarte.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if store.galleryFilter.hasActiveFilter {
                            Button("Filter zuruecksetzen") {
                                Task { await store.resetGalleryFilters() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(store.filteredPhotos) { photo in
                            PhotoGridCell(
                                photo: photo,
                                thumbnail: store.thumbnails[photo.handle],
                                isSelected: store.selectedHandles.contains(photo.handle),
                                isImported: store.importedFilenames.contains(photo.filename),
                                onToggleSelect: { store.toggleSelection(photo.handle) }
                            )
                            .onTapGesture {
                                previewPhoto = photo
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }

                if store.hasMorePhotos {
                    Button {
                        Task { await store.loadNextPhotoPage() }
                    } label: {
                        HStack(spacing: 8) {
                            if store.isLoadingMorePhotos {
                                ProgressView()
                            }
                            Text(store.isLoadingMorePhotos
                                 ? "Lade weitere Fotos..."
                                 : "Weitere Fotos laden (\(store.photos.count) / \(store.sessionInfo?.totalObjectCount ?? 0))")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .padding()
                    .disabled(store.isLoadingMorePhotos)
                }
            }

            bottomBar
        }
        .navigationTitle("Fotos")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $previewPhoto) { photo in
            PhotoPreviewView(store: store, initialPhoto: photo)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Trennen", role: .destructive) {
                    store.disconnect()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Neueste 5 auswaehlen") { store.selectLatest(5) }
                    Button("Neueste 10 auswaehlen") { store.selectLatest(10) }
                    Button("Neueste 20 auswaehlen") { store.selectLatest(20) }
                    Divider()
                    Button("Auswahl aufheben") { store.clearSelection() }
                } label: {
                    Image(systemName: "checklist")
                }
            }
        }
    }

    private func slotPicker(info: FujiSessionInfo) -> some View {
        Picker("SD-Karte", selection: Binding(
            get: { info.activeCardID },
            set: { newID in Task { await store.switchCard(to: newID) } }
        )) {
            ForEach(info.cards, id: \.id) { card in
                Text("\(card.name) (\(card.objectCount))").tag(card.id)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.selectedHandles.count) ausgewaehlt")
                        .font(.subheadline.weight(.semibold))
                    Text("Original-JPEG (6240 × 4160)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await store.downloadSelectedPhotos() }
                } label: {
                    Label("In Fotos laden", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedHandles.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }
}
