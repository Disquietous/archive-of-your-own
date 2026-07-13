import SwiftUI

/// The privacy popover anchored to the sidebar's Tor footer pill.
struct PrivacyPopoverView: View {
    @Bindable var theme: AppTheme
    let appState: AppState
    @Bindable var model: MacAppModel

    private struct Hop: Identifiable {
        let label: String, icon: String, tint: KeyPath<AppTheme, Color>
        var id: String { label }
    }

    private let hops = [
        Hop(label: "You", icon: "book", tint: \.ink2),
        Hop(label: "Guard", icon: "shield", tint: \.sage),
        Hop(label: "Relay", icon: "globe", tint: \.sage),
        Hop(label: "Exit", icon: "circle.circle", tint: \.accent),
        Hop(label: "AO3", icon: "building.columns", tint: \.ink2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.sage.opacity(0.15))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.sage)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(connected ? "Connected through Tor" : "Not connected")
                        .font(Font(MacFont.ui(14, weight: .bold)))
                        .foregroundStyle(theme.ink)
                    Text(connected ? "3-hop circuit · new identity available" : appState.torStatus.displayText)
                        .font(Font(MacFont.ui(11.5)))
                        .foregroundStyle(theme.ink3)
                }
            }
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                    VStack(spacing: 5) {
                        Circle()
                            .fill(theme[keyPath: hop.tint].opacity(0.16))
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: hop.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme[keyPath: hop.tint])
                            }
                        Text(hop.label)
                            .font(Font(MacFont.ui(10, weight: .semibold)))
                            .foregroundStyle(theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    if index < hops.count - 1 {
                        theme.line2.frame(width: 16, height: 2).offset(y: -8)
                    }
                }
            }
            .padding(.vertical, 10)

            Text("Your connection bounces through three volunteer relays before it reaches the archive. Nobody can link this device to what you read.")
                .font(Font(MacFont.ui(12.5)))
                .lineSpacing(3)
                .foregroundStyle(theme.ink2)
                .padding(.top, 4)

            Button {
                Task { await appState.connectTor() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(connected ? "New circuit" : "Connect")
                        .font(Font(MacFont.ui(13.5, weight: .bold)))
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            VStack(spacing: 0) {
                toggleRow("Hide explicit content", isOn: $model.hideExplicit)
                theme.line.frame(height: 1)
                toggleRow("New circuit on launch", isOn: .constant(theme.useTorByDefault))
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 300)
        .background(theme.surface)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Font(MacFont.ui(13.5, weight: .medium)))
                .foregroundStyle(theme.ink)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.sage)
        }
        .padding(.vertical, 11)
    }

    private var connected: Bool {
        appState.torStatus.isConnected
    }
}
