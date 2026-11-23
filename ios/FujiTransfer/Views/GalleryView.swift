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
                    ContentUnavailableView {
                        Label(
                            store.galleryFilter.hasActiveFilter
                                ? "Keine passenden Fotos"
                                : "Keine Fotos gefunden",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    } description: {
                        Text(
                            store.galleryFilter.hasActiveFilter
                                ? "Für die aktiven Filter wurden keine Fotos gefunden."
                                : "Auf dieser Speicherkarte sind keine Fotos vorhanden."
                        )
                    } actions: {
                        if store.galleryFilter.hasActiveFilter {
                            Button("Filter zurücksetzen") {
                                Task { await store.resetGalleryFilters() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 32)
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
                    .padding(.bottom, 12)
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
                                 ? "Lade weitere Fotos…"
                                 : "Weitere Fotos laden (\(store.photos.count) / \(store.sessionInfo?.totalObjectCount ?? 0))")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding()
                    .disabled(store.isLoadingMorePhotos)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    Button("Neueste 5 auswählen") { store.selectLatest(5) }
                    Button("Neueste 10 auswählen") { store.selectLatest(10) }
                    Button("Neueste 20 auswählen") { store.selectLatest(20) }
                    Divider()
                    Button("Auswahl aufheben") { store.clearSelection() }
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("Auswahloptionen")
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
                    Text("\(store.selectedHandles.count) ausgewählt")
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
                .controlSize(.regular)
                .disabled(store.selectedHandles.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
