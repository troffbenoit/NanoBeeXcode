//
//  NanoLinkManager.swift
//  NanoBee
//
//  Created by Stanley Benoit on 12/17/25.
//

//
//  NanoLinkManager.swift
//  NanoBee
//
//  PURPOSE:
//    - Perform handshake after connect
//    - Periodically ping the Nano (keep-alive)
//    - Track whether the Nano is responsive
//    - Ask the Nano what mode it is in
//
//  DESIGN RULES (NASA POWER OF 10):
//    - No recursion
//    - No dynamic memory allocation
//    - Bounded timers
//    - Explicit state transitions
//    - One responsibility per object
//

import Foundation
import Combine

// =============================================================
// MARK: - NanoLinkManager
// =============================================================

final class NanoLinkManager: ObservableObject {

    // ---------------------------------------------------------
    // PUBLIC, UI-OBSERVABLE STATE
    // ---------------------------------------------------------

    /// True if the Nano has responded recently.
    @Published var linkIsAlive: Bool = false

    /// Human-readable mode string reported by Nano.
    @Published var nanoModeText: String = "Unknown"

    /// Last time we received ANY valid line from the Nano.
    @Published var lastRxTimestamp: Date? = nil

    // ---------------------------------------------------------
    // PRIVATE CONSTANTS (TIMING)
// ---------------------------------------------------------

    /// How often we send a keep-alive ping.
    private let pingIntervalSeconds: TimeInterval = 1.0

    /// How long we tolerate silence before declaring link dead.
    private let timeoutSeconds: TimeInterval = 3.5

    // ---------------------------------------------------------
    // PRIVATE STATE
    // ---------------------------------------------------------

    private weak var serialManager: SerialManager?
    private var timer: DispatchSourceTimer?

    // ---------------------------------------------------------
    // INITIALIZATION
    // ---------------------------------------------------------

    init(serialManager: SerialManager) {
        self.serialManager = serialManager
    }

    deinit {
        stop()
    }

    // ---------------------------------------------------------
    // MARK: - Public Control API
    // ---------------------------------------------------------

    /// Call this immediately after a successful serial connect.
    func start() {
        performHandshake()
        startTimer()
    }

    /// Call this when the serial link closes.
    func stop() {
        timer?.cancel()
        timer = nil
        linkIsAlive = false
        nanoModeText = "Disconnected"
    }

    /// Notify the link manager that a line was received.
    /// SerialManager should call this for EVERY RX line.
    func notifyLineReceived(_ line: String) {
        lastRxTimestamp = Date()
        linkIsAlive = true

        parseStatusLineIfPresent(line)
    }

    // ---------------------------------------------------------
    // MARK: - Handshake
    // ---------------------------------------------------------

    private func performHandshake() {
        // Ask Nano who it is
        serialManager?.sendManualCommandLine("ID")

        // Ask Nano what mode it is in
        serialManager?.sendManualCommandLine("STATUS")
    }

    // ---------------------------------------------------------
    // MARK: - Keep-Alive Timer
    // ---------------------------------------------------------

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

        t.schedule(
            deadline: .now() + pingIntervalSeconds,
            repeating: pingIntervalSeconds
        )

        t.setEventHandler { [weak self] in
            self?.tick()
        }

        t.resume()
        timer = t
    }

    private func tick() {
        guard let lastRx = lastRxTimestamp else {
            linkIsAlive = false
            return
        }

        let age = Date().timeIntervalSince(lastRx)

        if age > timeoutSeconds {
            linkIsAlive = false
        } else {
            // Send keep-alive ping
            serialManager?.sendManualCommandLine("PING")
        }
    }

    // ---------------------------------------------------------
    // MARK: - STATUS Parsing
    // ---------------------------------------------------------

    private func parseStatusLineIfPresent(_ line: String) {
        // Expected future format example:
        //   STATUS MODE=PWM WALK=0 VENOM=0

        guard line.hasPrefix("STATUS") else { return }

        // Very simple parse for now
        if let modeRange = line.range(of: "MODE=") {
            let mode = line[modeRange.upperBound...]
                .split(separator: " ")
                .first
            nanoModeText = mode.map(String.init) ?? "Unknown"
        }
    }
}
