import SwiftUI

struct TransferOverlayView: View {
    let state: TransferProgressState
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if state.isFinished {
                    Image(systemName: state.failedFilenames.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(state.failedFilenames.isEmpty ? .green : .orange)

                    Text(state.wasCancelled ? "Uebertragung abgebrochen" : "Uebertragung abgeschlossen")
                        .font(.headline)

                    Text("\(state.completedCount) von \(state.totalCount) Fotos in deiner Mediathek gespeichert.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !state.failedFilenames.isEmpty {
                        Text("Fehlgeschlagen: \(state.failedFilenames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    Button("Fertig", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Uebertrage Foto \(state.currentIndex) von \(state.totalCount)")
                        .font(.headline)

                    Text(state.currentFilename)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)

                    ProgressView(value: state.currentFileFraction)
                        .progressViewStyle(.linear)

                    HStack {
                        let mbDone = Double(state.bytesReceived) / 1_048_576.0
                        let mbTotal = Double(state.totalBytes) / 1_048_576.0
                        Text(state.totalBytes > 0
                             ? String(format: "%.1f / %.1f MB", mbDone, mbTotal)
                             : "Starte Transfer...")
                        Spacer()
                        if state.lastSpeedMBps > 0 {
                            Text(String(format: "%.2f MB/s", state.lastSpeedMBps))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button("Abbrechen", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
            .padding()
        }
    }
}
