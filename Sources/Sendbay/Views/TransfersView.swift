import SwiftUI

struct TransfersButton: View {
    @Environment(DeviceStore.self) private var store
    @State private var showing = false

    var body: some View {
        let center = store.transfers
        Button { showing.toggle() } label: {
            if center.active.isEmpty {
                Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
            } else {
                ProgressView(value: center.overallFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .help("Transfers")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TransfersView().environment(store)
        }
        .onChange(of: center.items.count) { old, new in
            if new > old { showing = true }
        }
        .accessibilityIdentifier("transfersButton")
    }
}

struct TransfersView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        let center = store.transfers
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .disabled(center.items.allSatisfy(\.isActive))
            }
            .padding(12)
            Divider()
            if center.items.isEmpty {
                Text("No transfers yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(center.items) { transfer in
                            TransferRow(transfer: transfer)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 340)
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title).lineLimit(1).truncationMode(.middle)
                if transfer.isActive {
                    ProgressView(value: transfer.fraction).controlSize(.small)
                }
                Text(status).font(.caption).foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
            if transfer.isActive {
                Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        switch transfer.state {
        case .running: "\(Format.bytes(transfer.done)) of \(Format.bytes(transfer.total))"
        case .done: "Done · \(Format.bytes(transfer.total))"
        case .cancelled: "Cancelled"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        if case .failed = transfer.state { return .red }
        return .secondary
    }
}
