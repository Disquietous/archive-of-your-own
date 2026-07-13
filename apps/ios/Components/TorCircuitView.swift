import SwiftUI

struct TorCircuitView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    @State private var selectedHopIndex: Int?
    @State private var pulsePhase: Int = 0
    @State private var pulseTimer: Timer?

    struct HopInfo: Identifiable {
        let id: Int
        let icon: String
        let label: String
        let address: String
        let country: String
        let isTappable: Bool
    }

    private var hops: [HopInfo] {
        let circuitHops = state.bridge.circuitHops
        let connected = state.bridge.torStatus.isConnected

        if connected && !circuitHops.isEmpty {
            var result = [HopInfo(id: 0, icon: "iphone", label: "You", address: "", country: "", isTappable: false)]
            for (i, hop) in circuitHops.enumerated() {
                let icon = switch hop.role {
                case "Guard": "shield.lefthalf.filled"
                case "Exit": "arrow.up.forward"
                default: "arrow.triangle.swap"
                }
                result.append(HopInfo(
                    id: i + 1, icon: icon, label: hop.role,
                    address: hop.address, country: hop.country, isTappable: true
                ))
            }
            result.append(HopInfo(id: 4, icon: "globe", label: "AO3", address: "archiveofourown.org", country: "", isTappable: false))
            return result
        }

        return [
            HopInfo(id: 0, icon: "iphone", label: "You", address: "", country: "", isTappable: false),
            HopInfo(id: 1, icon: "shield.lefthalf.filled", label: "Guard", address: "", country: "", isTappable: false),
            HopInfo(id: 2, icon: "arrow.triangle.swap", label: "Relay", address: "", country: "", isTappable: false),
            HopInfo(id: 3, icon: "arrow.up.forward", label: "Exit", address: "", country: "", isTappable: false),
            HopInfo(id: 4, icon: "globe", label: "AO3", address: "", country: "", isTappable: false),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
                if index > 0 {
                    connectorView(index: index)
                }
                nodeView(hop: hop, index: index)
            }
        }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: state.bridge.torStatus) { _, newStatus in
            if newStatus == .connecting { startPulseIfNeeded() }
            if newStatus.isConnected { stopPulse() }
        }
        .onDisappear { stopPulse() }
    }

    private func startPulseIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                pulsePhase = (pulsePhase + 1) % 6
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func nodeView(hop: HopInfo, index: Int) -> some View {
        let connected = state.bridge.torStatus.isConnected
        let connecting = state.bridge.torStatus == .connecting
        let isEndpoint = index == 0 || index == hops.count - 1
        let isRelay = !isEndpoint && (index >= 1 && index <= 3)
        let isPulsing = connecting && isRelay && (pulsePhase / 2) + 1 == index
        let color: Color = {
            if connected { return isEndpoint ? theme.ink2 : theme.sage }
            if connecting { return isEndpoint ? theme.ink2 : theme.accent2 }
            return theme.ink3
        }()

        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(color.opacity(isPulsing ? 0.35 : 0.12))
                    .frame(width: 34, height: 34)

                Image(systemName: hop.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
                    .opacity(isPulsing ? 0.5 : 1.0)
            }
            .overlay(alignment: .top) {
                if selectedHopIndex == index && hop.isTappable && !hop.address.isEmpty {
                    addressBalloon(hop.address)
                        .offset(y: -38)
                }
            }
            .onTapGesture {
                guard hop.isTappable else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedHopIndex = selectedHopIndex == index ? nil : index
                }
            }

            Text(hop.label)
                .font(.custom("HankenGrotesk", size: 10).weight(.bold))
                .foregroundStyle(theme.ink)

            if !hop.country.isEmpty && hop.country != "??" {
                Text(hop.country.uppercased())
                    .font(.custom("HankenGrotesk", size: 18).weight(.bold))
                    .foregroundStyle(theme.ink3)
            } else {
                Text(" ")
                    .font(.custom("HankenGrotesk", size: 18))
            }
        }
        .frame(minWidth: 46)
    }

    private func connectorView(index: Int) -> some View {
        let connected = state.bridge.torStatus.isConnected
        let connecting = state.bridge.torStatus == .connecting

        return Rectangle()
            .fill(connected ? theme.sage : connecting ? theme.accent2.opacity(0.4) : theme.line2)
            .frame(height: connected ? 2 : 1.5)
            .frame(maxWidth: .infinity)
            .offset(y: -10)
    }

    private func addressBalloon(_ address: String) -> some View {
        Text(address)
            .font(.system(size: 11, design: .monospaced).weight(.medium))
            .foregroundStyle(theme.onAccent)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.ink))
            .fixedSize()
            .transition(.scale.combined(with: .opacity))
    }
}
