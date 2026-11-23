import SwiftUI
import FujiCore

/// Kompakte horizontale Filterleiste ueber dem Galerie-Grid:
/// - Aufnahmedatum (lokal, sofort)
/// - Import-Status (Alle / Neu / Importiert)
/// - Kamera-Sterne (XApp-Sternfilter 0xD603 direkt auf der X-T4)
struct GalleryFilterBar: View {
    let store: CameraSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    starFilterMenu
                    importFilterMenu

                    if !store.availableDateOptions.isEmpty {
                        Divider().frame(height: 18)

                        dateChip(
                            title: "Alle Tage",
                            isSelected: store.galleryFilter.selectedDateKey == nil
                        ) {
                            store.galleryFilter.selectedDateKey = nil
                        }

                        ForEach(store.availableDateOptions) { day in
                            dateChip(
                                title: "\(day.label) (\(day.count))",
                                isSelected: store.galleryFilter.selectedDateKey == day.key
                            ) {
                                store.galleryFilter.selectedDateKey =
                                    (store.galleryFilter.selectedDateKey == day.key) ? nil : day.key
                            }
                        }

                        if store.hasMorePhotos {
                            Button {
                                Task { await store.loadAllRemainingMetadata() }
                            } label: {
                                Label(
                                    store.isLoadingMorePhotos ? "Lädt…" : "Alle Tage laden",
                                    systemImage: "arrow.down.circle"
                                )
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                            .disabled(store.isLoadingMorePhotos)
                        }
                    }

                    if store.galleryFilter.hasActiveFilter {
                        Button("Zurücksetzen") {
                            Task { await store.resetGalleryFilters() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if let notice = store.galleryFilter.starFilterNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var starFilterMenu: some View {
        Menu {
            ForEach(FujiStarRatingFilter.allCases) { option in
                Button {
                    Task { await store.applyCameraStarFilter(option) }
                } label: {
                    if store.galleryFilter.starFilter == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if store.isApplyingFilter {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: store.galleryFilter.starFilter == .all ? "star" : "star.fill")
                        .font(.caption2)
                }
                Text(store.galleryFilter.starFilter.label)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(store.galleryFilter.starFilter == .all ? Color.primary : Color.orange)
            .background(
                (store.galleryFilter.starFilter == .all ? Color(uiColor: .tertiarySystemFill) : Color.orange.opacity(0.16)),
                in: Capsule()
            )
        }
        .disabled(store.isApplyingFilter || store.sessionInfo?.effectiveMode != .xapp)
    }

    private var importFilterMenu: some View {
        Menu {
            ForEach(GalleryImportFilter.allCases) { option in
                Button {
                    store.galleryFilter.importFilter = option
                } label: {
                    if store.galleryFilter.importFilter == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption2)
                Text(store.galleryFilter.importFilter == .all ? "Status: Alle" : store.galleryFilter.importFilter.rawValue)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(store.galleryFilter.importFilter == .all ? Color.primary : Color.accentColor)
            .background(
                (store.galleryFilter.importFilter == .all ? Color(uiColor: .tertiarySystemFill) : Color.accentColor.opacity(0.16)),
                in: Capsule()
            )
        }
    }

    private func dateChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
