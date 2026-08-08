import SwiftUI

// MARK: - Tor connection & Cloudflare

extension AppState {
    func connectTor() async {
        let wasConnected = bridge.torStatus.isConnected
        // Always persist session cookies before the transport swap wipes the
        // jar — the Rust side refuses to overwrite authenticated cookies with
        // an anonymous jar, so this is safe even when logged out. (Previously
        // gated on wasConnected, which lost sessions established while
        // disconnected — surfacing as bogus "session expired" moments later.)
        bridge.saveSessionCookies()

        torConnectCancelled = false
        torConnectFailed = false
        var attempts = 0

        while !torConnectCancelled {
            await bridge.connectTor()
            guard bridge.torStatus.isConnected else {
                torConnectFailed = true
                return
            }

            attempts += 1
            isTestingCircuit = true
            circuitAttempt = attempts
            let healthy = await bridge.checkCircuitHealth()
            isTestingCircuit = false

            if torConnectCancelled { break }

            if healthy {
                bridge.writeLog(level: "INFO", tag: "health", message: "Circuit passed health check on attempt \(attempts)")
                await resolveCloudflare()
                // Always restore after the swap, not only on reconnects —
                // the new transport starts with an empty jar.
                bridge.restoreSessionCookies()
                torConnectFailed = false
                return
            }

            bridge.writeLog(level: "WARN", tag: "health", message: "Circuit failed health check (\(attempts)), trying another")
        }

        if torConnectCancelled {
            bridge.writeLog(level: "INFO", tag: "health", message: "Circuit search cancelled by user after \(attempts) attempts")
            torConnectFailed = true
        }
    }

    /// User-initiated circuit rotation. The user only reaches for this when
    /// the current circuit is presumed dead, so abort the in-flight request
    /// first — otherwise the rotation queues behind the Rust client lock
    /// until that request finishes or times out. Automatic rotation paths
    /// (retry-on-timeout) keep their settle-and-wait behavior.
    func newCircuitNow() async -> Bool {
        bridge.cancelRequest()
        return await bridge.newCircuit()
    }

    /// User-initiated full reconnect (the hub's "New circuit" / "Connect"
    /// button). Same contract as newCircuitNow(): the user reaches for this
    /// when the current circuit is presumed dead, so abort the in-flight
    /// request instead of queueing the transport swap behind it.
    func connectTorNow() async {
        bridge.cancelRequest()
        await connectTor()
    }

    func rotateCircuit() async {
        // Coalesce: if a rotation is already running (another request hit the
        // same dead circuit), wait for it instead of rotating again — the
        // caller retries on the fresh circuit either way.
        if isRotatingCircuit {
            while isRotatingCircuit {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return
        }
        isRotatingCircuit = true
        defer { isRotatingCircuit = false }

        // Let other in-flight requests settle before replacing the transport —
        // rotating mid-flight kills them, and their timeouts would trigger
        // another rotation in a cascade. Cap the wait: on a truly dead
        // circuit those requests only end at their own timeout anyway.
        var waitedMs = 0
        while !bridge.getActiveRequests().isEmpty && waitedMs < 15_000 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitedMs += 500
        }

        bridge.saveSessionCookies()

        torConnectCancelled = false
        torConnectFailed = false
        var attempts = 0

        while !torConnectCancelled {
            let ok = await bridge.newCircuit()
            if !ok {
                bridge.writeLog(level: "WARN", tag: "circuit", message: "new_circuit() failed, falling back to full reconnect")
                await connectTor()
                return
            }

            attempts += 1
            isTestingCircuit = true
            circuitAttempt = attempts
            let healthy = await bridge.checkCircuitHealth()
            isTestingCircuit = false

            if torConnectCancelled { break }

            if healthy {
                bridge.writeLog(level: "INFO", tag: "circuit", message: "New circuit passed health check on attempt \(attempts)")
                await resolveCloudflare()
                bridge.restoreSessionCookies()
                torConnectFailed = false
                return
            }

            bridge.writeLog(level: "WARN", tag: "circuit", message: "New circuit failed health check (\(attempts)), trying another")
        }

        if torConnectCancelled {
            bridge.writeLog(level: "INFO", tag: "circuit", message: "Circuit search cancelled by user after \(attempts) attempts")
            torConnectFailed = true
        }
    }

    func cancelTorConnect() {
        torConnectCancelled = true
        isTestingCircuit = false
        isResolvingCloudflare = false
    }

    func proceedWithCurrentCircuit() async {
        cancelTorConnect()
        torConnectFailed = false
        bridge.writeLog(level: "WARN", tag: "health", message: "User chose to proceed with untested circuit")
        await resolveCloudflare()
    }

    func ensureTorConnected() async -> Bool {
        guard bridge.torRequired else { return true }
        if bridge.torStatus.isConnected { return true }

        showTorConnectOverlay = true
        await connectTor()

        if bridge.torStatus.isConnected {
            showTorConnectOverlay = false
            return true
        }
        return false
    }

    /// Load AO3 in a hidden WKWebView routed through our Tor SOCKS proxy to
    /// pass Cloudflare's challenge and obtain the cf_clearance cookie.
    @MainActor
    func resolveCloudflare() async {
        let port = bridge.getSocksPort()
        guard port > 0 else {
            bridge.writeLog(level: "WARN", tag: "cloudflare", message: "Skipping: no SOCKS port")
            return
        }

        isResolvingCloudflare = true
        cloudflareError = nil
        bridge.writeLog(level: "INFO", tag: "cloudflare", message: "Starting challenge resolution via SOCKS port \(port)")

        do {
            let resolver = CloudflareResolver()
            let resolved = try await resolver.resolve(socksPort: port)

            // Restore auth cookies first (connectTor wiped them)
            bridge.restoreSessionCookies()

            // Then inject CF cookies on top
            if !resolved.cookies.isEmpty {
                bridge.injectCookies(resolved.cookies)
            }
            cloudflareResolved = true
            bridge.writeLog(level: "INFO", tag: "cloudflare",
                message: "Done: cf_clearance=\(resolved.hasCfClearance), \(resolved.cookies.count) CF cookies injected")
        } catch {
            cloudflareError = error.localizedDescription
            bridge.writeLog(level: "ERROR", tag: "cloudflare",
                message: "Resolution failed: \(error.localizedDescription)")
            // The transport swap emptied the jar before we got here; a failed
            // challenge must not also cost the login session.
            bridge.restoreSessionCookies()
        }

        isResolvingCloudflare = false
        bridge.cloudflareReady = true
        // The challenge traffic ran through the SOCKS bridge, so the captured
        // circuit path is fresh — reflect it in the UI.
        bridge.refreshCircuitHops()
    }
}
