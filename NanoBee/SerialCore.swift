//
//  SerialCore.swift
//  NanoBee
//
//  Created by Stanley Benoit on 12/22/25.
//
//  Serial + Manager core types extracted from ContentView.swift.
//  This file should compile on its own without requiring ContentView changes.
//
//  =====================================================================
//  CHANGE LOG (timestamped so we can track growth)
//  =====================================================================
//
//  2025-12-22  - BASE
//              - Added SerialPort (POSIX) for open/close/termios/read/write.
//              - Added SerialManager (ObservableObject) for UI + command parsing.
//
//  2025-12-26  - CHANGE
//              - Added App-side KeepAlive + Link Watchdog:
//                  * Timer sends "PING\n" every keepAliveIntervalSec
//                  * If we hear nothing for linkTimeoutSec repeatedly,
//                    we disconnect safely.
//              - Added LED state for UI:
//                  * @Published isLinkAlive (green = alive, red = dead)
//
//  2025-12-28  - CHANGE (VENOM + MODE PARSING FOR UI)
//              - Added Nano “mode” tracking on the Mac side:
//                  * Parses "MODE <name>" lines from firmware.
//                  * Publishes nanoModeString for UI badges / display.
//              - Added VENOM status parsing on the Mac side:
//                  * Parses "OK VENOM ON ..." and "OK VENOM OFF" / "OK STOP".
//                  * Publishes isVenomRunning, lastVenomFrequencyHz,
//                    lastVenomOnMs, lastVenomOffMs.
//              - Made OK parsing safer:
//                  * Only treats "OK F= D= A=" as PWM config verification.
//                  * Does NOT accidentally treat "OK VENOM ON F=..." as config.
//              - Added optional bounded log growth (hard cap) to prevent
//                runaway memory if you leave it running for days.
//
//  =====================================================================
//  NASA “POWER OF 10” STYLE RULES (practical Swift version)
//  =====================================================================
//
//  1) No recursion.
//  2) No infinite loops:
//       - SerialPort write retries are bounded.
//       - KeepAlive timer can be stopped.
//  3) Bounded memory:
//       - RX buffer has a hard cap.
//       - (Optional) logText is capped to a max size.
//  4) Validate inputs before acting:
//       - Don’t send if port isn’t open.
//       - Ignore empty manual commands.
//  5) Single source of truth for serial + connection state: SerialManager.
//  6) Safe failure:
//       - If link looks dead -> disconnect.
//       - Firmware should also STOP on lost host.
//  7) Clear ownership signals:
//       - Firmware reports MODE; app displays it (no guessing).
//  8) Keep behavior visible and testable:
//       - TX/RX are logged verbosely.
//  9) Errors are explicit:
//       - ERR lines set statusMessage and log an error tag.
// 10) Prefer simple, readable code over cleverness.
//      (If it’s confusing, it’s dangerous.)
//
//  =====================================================================
//  4-YEAR-OLD EXPLANATION (yes, really)
//  =====================================================================
//
//  - SerialPort is the “USB walkie-talkie”.
//  - SerialManager is the “translator” for the walkie-talkie:
//      * It sends words like "PING" or "SET".
//      * It listens for words like "OK", "ERR", "MODE VENOM".
//  - The UI watches SerialManager and redraws when these values change.
//

import Foundation
import Combine
import Darwin

// =============================================================
// MARK: - Verified Configuration Model
// =============================================================
//
// VARIABLES DEFINED IN THIS SECTION
// - VerifiedConfiguration fields:
//   * frequencyHz        : Double  — “how fast the PWM wiggles”
//   * dutyCyclePercent   : Double  — “how long it stays ON each wiggle”
//   * amplitude          : Double  — “how strong it is (0..1)”
//   * timestamp          : Date    — “when Nano last confirmed settings”
//
// Written by: SerialManager.parseOkPwmConfigLine(...)
// Read by:    UI via SerialManager.lastVerifiedConfiguration
//

/// Configuration that the Arduino has confirmed via an "OK F=... D=... A=..." line.
/// This is treated as the **ground truth** of what is actually set on the Nano at this moment.
struct VerifiedConfiguration {
    let frequencyHz: Double
    let dutyCyclePercent: Double
    let amplitude: Double
    let timestamp: Date
}

// =============================================================
// MARK: - Serial Communication Core (POSIX SerialPort)
// =============================================================
//
// SerialPort = “USB walkie-talkie”
//
// It does NOT understand commands like "VENOM".
// It only does:
//   - open the door
//   - set baud rate
//   - send bytes
//   - receive bytes
//   - turn bytes into whole text lines
//

final class SerialPort {

    // -------------------------------------------------------------
    // MARK: - Stored Properties (Variables) for SerialPort
    // -------------------------------------------------------------
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - path: String
    //     “Which serial door to open” (ex: /dev/cu.usbserial-110)
    //
    // - fileDescriptor: Int32
    //     “The OS handle for the open door”
    //     -1 means closed.
    //
    // - readSource: DispatchSourceRead?
    //     “The listener that wakes up when bytes arrive”
    //
    // - receiveBuffer: String
    //     “Text we got that hasn’t become full lines yet”
    //
    // - maxReceiveBufferChars: Int
    //     “Safety cap so a broken device can’t eat memory”
    //
    // - lineReceivedHandler: ((String) -> Void)?
    //     “Callback to deliver complete lines to SerialManager”
    //
    // - lastErrorMessage: String?
    //     “Human readable error message”
    //
    // Written by: open/close/startReadLoop/processIncomingChunk/sendString
    // Read by:    SerialManager, isOpen, sendString
    //

    /// Filesystem path to the serial device (for example "/dev/cu.usbserial-...").
    let path: String

    /// POSIX file descriptor for the open device.  -1 means "currently closed".
    private var fileDescriptor: Int32 = -1

    /// Dispatch source used to get a callback when bytes are ready to read.
    private var readSource: DispatchSourceRead?

    /// Buffer that holds partial line fragments between read events.
    private var receiveBuffer: String = ""

    /// Hard cap for receiveBuffer size (characters).
    /// If we exceed this, we drop the buffer and keep going safely.
    private let maxReceiveBufferChars: Int = 16_384

    /// Closure called on the **main queue** whenever a full line is received.
    var lineReceivedHandler: ((String) -> Void)?

    /// Human-readable description of the last error (if any).
    private(set) var lastErrorMessage: String? = nil

    // MARK: - Initialization / Deinit
    //
    // VARIABLES USED IN THIS SECTION
    // - path: stored from init
    // - close(): called in deinit to prevent FD leaks
    //

    init(path: String) {
        self.path = path
    }

    deinit {
        // Make sure we do not leak file descriptors.
        close()
    }

    // MARK: - Public interface
    //
    // VARIABLES USED IN THIS SECTION
    // - fileDescriptor: determines isOpen
    // - lastErrorMessage: set on failures
    //

    /// True if the port is currently open.
    var isOpen: Bool {
        fileDescriptor != -1
    }

    /// Open and configure the port at the specified baud rate.
    /// Returns true on success, false on any error.
    func open(baudRate: Int) -> Bool {
        // Ensure any previous handle is closed first.
        close()

        // O_RDWR      = open for read + write
        // O_NOCTTY    = do not treat as controlling terminal
        // O_NONBLOCK  = non-blocking mode (we use DispatchSourceRead)
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd == -1 {
            lastErrorMessage = String(cString: strerror(errno))
            return false
        }

        // Configure termios.
        if !configureTermios(fileDescriptor: fd, baudRate: baudRate) {
            lastErrorMessage = String(cString: strerror(errno))
            Darwin.close(fd)
            return false
        }

        // If we get here, fd is valid and configured.
        fileDescriptor = fd
        startReadLoop()
        lastErrorMessage = nil
        return true
    }

    /// Close the port if open.
    func close() {
        // Stop the read source (if any) first.
        readSource?.cancel()
        readSource = nil

        // Clear any residual text fragments.
        receiveBuffer = ""

        // Close the file descriptor if it is valid.
        if fileDescriptor != -1 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// Send a UTF-8 string over the serial port.
    ///
    /// IMPORTANT:
    /// write() may write fewer bytes than requested, so we retry.
    /// We cap retries (NASA-ish) so we never loop forever.
    func sendString(_ string: String) -> Bool {
        guard isOpen else {
            lastErrorMessage = "Port is not open."
            return false
        }

        guard let data = string.data(using: .utf8) else {
            lastErrorMessage = "Failed to encode string as UTF-8."
            return false
        }

        // Convert Data to a stable byte array so we can do pointer math safely.
        let bytes = [UInt8](data)
        var totalWritten = 0

        // Bounded retry count (no infinite loop).
        var attempts = 0
        let maxAttempts = 50

        while totalWritten < bytes.count && attempts < maxAttempts {

            let remaining = bytes.count - totalWritten

            let written: Int = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                let ptr = base.advanced(by: totalWritten)
                return Darwin.write(fileDescriptor, ptr, remaining)
            }

            if written > 0 {
                totalWritten += written
                continue
            }

            if written == 0 {
                lastErrorMessage = "write() returned 0 (no progress)."
                return false
            }

            // written < 0 => error
            if errno == EAGAIN || errno == EWOULDBLOCK {
                attempts += 1
                usleep(1_000) // 1ms backoff (bounded)
                continue
            }

            lastErrorMessage = String(cString: strerror(errno))
            return false
        }

        if totalWritten != bytes.count {
            lastErrorMessage = "write() incomplete after retries."
            return false
        }

        lastErrorMessage = nil
        return true
    }

    // MARK: - Private helpers

    /// Map integer baud to POSIX speed_t.
    private func baudRateToSpeed(_ baudRate: Int) -> speed_t? {
        switch baudRate {
        case 9600:   return speed_t(B9600)
        case 19200:  return speed_t(B19200)
        case 38400:  return speed_t(B38400)
        case 57600:  return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default:     return nil
        }
    }

    /// Configure termios for 8N1, raw mode, at given baud.
    private func configureTermios(fileDescriptor fd: Int32, baudRate: Int) -> Bool {
        var options = termios()

        if tcgetattr(fd, &options) != 0 {
            return false
        }

        guard let speed = baudRateToSpeed(baudRate) else {
            errno = EINVAL
            return false
        }

        if cfsetispeed(&options, speed) != 0 { return false }
        if cfsetospeed(&options, speed) != 0 { return false }

        // 8 data bits, ignore modem ctl, enable receiver.
        options.c_cflag |= (tcflag_t(CS8) | tcflag_t(CLOCAL) | tcflag_t(CREAD))

        // No parity, 1 stop bit, no HW flow control.
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
#if os(macOS)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
#endif

        // Raw input: no canonical mode, echo, or signals.
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)

        // No software flow control or CR/LF translation.
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_iflag &= ~tcflag_t(ICRNL | INLCR)

        // Raw output.
        options.c_oflag &= ~tcflag_t(OPOST)

        return tcsetattr(fd, TCSANOW, &options) == 0
    }

    /// Start async read loop using DispatchSourceRead.
    private func startReadLoop() {
        guard isOpen, readSource == nil else { return }

        let queue = DispatchQueue.global(qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = Darwin.read(self.fileDescriptor, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                if let chunk = String(data: data, encoding: .utf8) {
                    self.processIncomingChunk(chunk)
                } else {
                    self.lastErrorMessage = "RX contained non-UTF8 bytes."
                }
            } else if bytesRead == 0 {
                // EOF: device closed from the other side.
                self.readSource?.cancel()
                self.readSource = nil
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                self.lastErrorMessage = String(cString: strerror(errno))
            }
        }

        source.resume()
        readSource = source
    }

    /// Accumulate text until newline; then deliver full lines.
    private func processIncomingChunk(_ chunk: String) {
        receiveBuffer.append(chunk)

        // Safety cap: if no newline ever arrives, we do not grow forever.
        if receiveBuffer.count > maxReceiveBufferChars {
            receiveBuffer = ""
            lastErrorMessage = "RX buffer overflow (line too long)."
            return
        }

        let parts = receiveBuffer.components(separatedBy: .newlines)

        // All elements except the last are complete lines.
        for i in 0..<(parts.count - 1) {
            let line = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                // Deliver on main queue so UI can update safely.
                DispatchQueue.main.async {
                    self.lineReceivedHandler?(line)
                }
            }
        }

        // Save residual fragment.
        receiveBuffer = parts.last ?? ""
    }
}

// =============================================================
// MARK: - Serial Manager (ObservableObject used by UI)
// =============================================================
//
// SerialManager is the “brain” the UI talks to.
// It owns all connection state and keeps it consistent.
//
// 4-year-old explanation:
// - It’s the grown-up who reads what the Nano says,
//   and tells the screen what to show.
//

final class SerialManager: ObservableObject {

    // =============================================================
    // MARK: - UI Published State (the UI watches these)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - availablePorts: [String]  — list of ports found under /dev
    // - selectedPortPath: String  — which port user chose
    // - isConnected: Bool         — connected yes/no
    // - baudRate: Int             — serial speed
    // - statusMessage: String     — human-readable status text
    // - lastVerifiedConfiguration: VerifiedConfiguration?
    // - logText: String           — full log shown in UI
    // - isLinkAlive: Bool         — LED state (true green / false red)
    //
    // NEW (2025-12-28):
    // - nanoModeString: String    — last "MODE <name>" reported by Nano
    // - isVenomRunning: Bool      — true after "OK VENOM ON", false after STOP/OFF
    // - lastVenomFrequencyHz: Double? — last F= reported in venom OK line (if present)
    // - lastVenomOnMs: Int?       — last T_ON reported (ms)
    // - lastVenomOffMs: Int?      — last T_OFF reported (ms)
    //

    @Published var availablePorts: [String] = []
    @Published var selectedPortPath: String = ""
    @Published var isConnected: Bool = false
    @Published var baudRate: Int = 115200
    @Published var statusMessage: String = "Not connected."
    @Published var lastVerifiedConfiguration: VerifiedConfiguration? = nil
    @Published var logText: String = ""
    @Published var isLinkAlive: Bool = false

    // NEW: Nano mode + venom status (for UI badges)
    @Published var nanoModeString: String = "UNKNOWN"
    @Published var isVenomRunning: Bool = false
    @Published var lastVenomFrequencyHz: Double? = nil
    @Published var lastVenomOnMs: Int? = nil
    @Published var lastVenomOffMs: Int? = nil

    // =============================================================
    // MARK: - Internal Serial Port Handle
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - serialPort: SerialPort?
    //   The actual open connection. nil means disconnected.
    //
    private var serialPort: SerialPort?

    // Safe baud list used by UI.
    let supportedBaudRates: [Int] = [9600, 19200, 38400, 57600, 115200, 230400]

    // =============================================================
    // MARK: - Keep Alive / Link Watchdog (App-side)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - keepAliveTimer: DispatchSourceTimer? — repeating timer
    // - lastRxLineAt: Date                   — last time we heard any RX line
    // - missedKeepAliveStrikes: Int          — consecutive timeouts
    //
    // Constants (tune me):
    // - keepAliveIntervalSec: Double — PING interval
    // - linkTimeoutSec: Double       — silence threshold
    // - maxStrikes: Int              — strikes before disconnect
    //
    private var keepAliveTimer: DispatchSourceTimer?
    private var lastRxLineAt: Date = Date()
    private var missedKeepAliveStrikes: Int = 0

    private let keepAliveIntervalSec: Double = 10.0
    private let linkTimeoutSec: Double = 25.0
    private let maxStrikes: Int = 3

    // =============================================================
    // MARK: - Log Safety Cap (optional but recommended)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - maxLogChars: Int
    //     Safety cap so logText does not grow forever.
    //
    // 4-year-old explanation:
    // - We don’t let the log become a giant monster.
    //
    private let maxLogChars: Int = 200_000

    init() {
        // ContentView triggers refresh on .task { }.
    }

    // =============================================================
    // MARK: - Logging helper
    // =============================================================
    //
    // VARIABLES USED IN THIS SECTION
    // - logText: appended here (must run on main thread)
    // - maxLogChars: used to trim old content
    //
    private func appendLog(_ line: String) {
        let work = { [weak self] in
            guard let self else { return }

            if self.logText.isEmpty {
                self.logText = line
            } else {
                self.logText += "\n" + line
            }

            // OPTIONAL HARD CAP: keep only the last maxLogChars characters.
            // This prevents runaway memory usage.
            if self.logText.count > self.maxLogChars {
                let start = self.logText.index(self.logText.endIndex,
                                               offsetBy: -self.maxLogChars)
                self.logText = String(self.logText[start...])
                self.logText = "[INFO] Log trimmed to last \(self.maxLogChars) chars.\n" + self.logText
            }

            print("[NanoBee] \(line)")
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // =============================================================
    // MARK: - KeepAlive internals
    // =============================================================
    //
    // VARIABLES USED IN THIS SECTION
    // - keepAliveTimer, lastRxLineAt, missedKeepAliveStrikes
    // - serialPort, isConnected
    // - statusMessage, isLinkAlive
    //
    private func startKeepAlive() {
        stopKeepAlive()

        lastRxLineAt = Date()
        missedKeepAliveStrikes = 0

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + keepAliveIntervalSec,
            repeating: keepAliveIntervalSec,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.keepAliveTick()
        }
        timer.resume()
        keepAliveTimer = timer

        appendLog("[INFO] KeepAlive started (PING every \(keepAliveIntervalSec)s, timeout \(linkTimeoutSec)s).")
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private func keepAliveTick() {
        guard isConnected, let port = serialPort, port.isOpen else { return }

        if port.sendString("PING\n") {
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("[TX] PING")
            }
        } else {
            let msg = port.lastErrorMessage ?? "Unknown error"
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("[WARN] KeepAlive PING write failed: \(msg)")
            }
        }

        let silence = Date().timeIntervalSince(lastRxLineAt)

        if silence > linkTimeoutSec {
            missedKeepAliveStrikes += 1

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appendLog("[WARN] KeepAlive timeout strike \(self.missedKeepAliveStrikes)/\(self.maxStrikes) (silence \(String(format: "%.2f", silence))s).")
            }

            if missedKeepAliveStrikes >= maxStrikes {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.appendLog("[ERROR] Link appears dead. Disconnecting for safety.")
                    self.statusMessage = "Connection lost (keep-alive timeout)."
                    self.isLinkAlive = false
                    self.disconnect()
                }
            }
        } else {
            missedKeepAliveStrikes = 0
        }
    }

    // =============================================================
    // MARK: - Port Discovery
    // =============================================================

    /// Scan /dev for USB-style serial ports on a background queue.
    func refreshAvailablePorts() {
        let devPath = "/dev"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String] = []

            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: devPath)
                for entry in entries {
                    if (entry.hasPrefix("cu.") || entry.hasPrefix("tty.")),
                       entry.lowercased().contains("usb") {
                        found.append(devPath + "/" + entry)
                    }
                }
            } catch {
                self?.appendLog("[ERROR] Failed to list /dev: \(error.localizedDescription)")
            }

            found.sort()

            DispatchQueue.main.async {
                guard let self = self else { return }

                self.availablePorts = found

                if let idx = found.firstIndex(of: self.selectedPortPath) {
                    self.selectedPortPath = found[idx]
                } else {
                    self.selectedPortPath = found.first ?? ""
                }

                self.appendLog("[INFO] Refreshed serial ports. Found \(found.count) candidate(s).")
                for path in found {
                    self.appendLog("[INFO]   Port candidate: \(path)")
                }
            }
        }
    }

    // =============================================================
    // MARK: - Connect / Disconnect
    // =============================================================

    func connect() {
        let path = selectedPortPath
        guard !path.isEmpty else {
            statusMessage = "No port selected."
            appendLog("[ERROR] connect() called with no port selected.")
            isLinkAlive = false
            return
        }

        let port = SerialPort(path: path)
        port.lineReceivedHandler = { [weak self] line in
            self?.handleReceivedLine(line)
        }

        appendLog("[INFO] Attempting to open \(path) @ \(baudRate) baud...")

        if port.open(baudRate: baudRate) {
            serialPort = port
            isConnected = true
            statusMessage = "Connected to \(path) @ \(baudRate) baud."
            appendLog("[INFO] Connected to \(path) @ \(baudRate) baud.")

            // Reset “truth” state on connect so UI doesn’t show stale values.
            nanoModeString = "UNKNOWN"
            isVenomRunning = false
            lastVenomFrequencyHz = nil
            lastVenomOnMs = nil
            lastVenomOffMs = nil

            startKeepAlive()
            isLinkAlive = true
        } else {
            let msg = port.lastErrorMessage ?? "Unknown error"
            serialPort = nil
            isConnected = false
            statusMessage = "Failed to open \(path): \(msg)"
            appendLog("[ERROR] Failed to open \(path): \(msg)")
            isLinkAlive = false
        }
    }

    func disconnect() {
        stopKeepAlive()
        isLinkAlive = false

        // Clear state so UI doesn’t show “VENOM ON” while disconnected.
        nanoModeString = "UNKNOWN"
        isVenomRunning = false

        guard let port = serialPort else {
            statusMessage = "No open port."
            appendLog("[WARN] disconnect() called but serialPort is nil.")
            return
        }

        appendLog("[INFO] Closing port \(port.path)...")
        port.close()
        serialPort = nil
        isConnected = false
        statusMessage = "Disconnected."
        appendLog("[INFO] Disconnected.")
    }

    // =============================================================
    // MARK: - Sending Configuration (structured SET command)
    // =============================================================

    func sendConfiguration(frequencyHz: Double,
                           dutyCyclePercent: Double,
                           amplitude: Double) {

        guard let port = serialPort, port.isOpen else {
            statusMessage = "Cannot send: not connected."
            appendLog("[ERROR] sendConfiguration() called while not connected.")
            return
        }

        // Minimal clamps here; firmware is the final gatekeeper.
        let safeFrequency = max(1.0, frequencyHz)
        let safeDuty = min(max(dutyCyclePercent, 0.0), 100.0)
        let safeAmplitude = max(amplitude, 0.0)

        let command = String(
            format: "SET F=%.3f D=%.3f A=%.3f\n",
            safeFrequency,
            safeDuty,
            safeAmplitude
        )

        if port.sendString(command) {
            statusMessage = "Sent config: F=\(safeFrequency) Hz, D=\(safeDuty) %."
            appendLog("[TX] \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            let msg = port.lastErrorMessage ?? "Unknown error"
            statusMessage = "Failed to write: \(msg)"
            appendLog("[ERROR] write() failed when sending configuration: \(msg)")
        }
    }

    // =============================================================
    // MARK: - Manual command (free-form)
    // =============================================================

    func sendManualCommandLine(_ text: String) {
        guard let port = serialPort, port.isOpen else {
            statusMessage = "Cannot send manual command: not connected."
            appendLog("[ERROR] Manual command attempted while not connected.")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("[WARN] Ignoring empty manual command.")
            return
        }

        var lineToSend = trimmed
        if !lineToSend.hasSuffix("\n") {
            lineToSend.append("\n")
        }

        if port.sendString(lineToSend) {
            appendLog("[TX(MANUAL)] \(trimmed)")
            statusMessage = "Manual command sent."
        } else {
            let msg = port.lastErrorMessage ?? "Unknown error"
            statusMessage = "Failed to write manual command: \(msg)"
            appendLog("[ERROR] write() failed when sending manual command: \(msg)")
        }
    }

    // =============================================================
    // MARK: - Log management
    // =============================================================

    func clearLog() {
        logText = ""
        appendLog("[INFO] Log cleared by user.")
    }

    // =============================================================
    // MARK: - Incoming Line Handling (RX parser)
    // =============================================================
    //
    // VARIABLES WRITTEN IN THIS SECTION
    // - lastRxLineAt, missedKeepAliveStrikes, isLinkAlive
    // - statusMessage/logText
    // - lastVerifiedConfiguration (when PWM OK line parsed)
    // - nanoModeString (when MODE line parsed)
    // - isVenomRunning / lastVenom... (when VENOM/STOP lines parsed)
    //
    private func handleReceivedLine(_ line: String) {
        lastRxLineAt = Date()
        missedKeepAliveStrikes = 0
        isLinkAlive = true

        appendLog("[RX] \(line)")

        // 1) MODE parsing (firmware mutual exclusion truth)
        if line.hasPrefix("MODE ") {
            parseModeLine(line)
            return
        }

        // 2) OK parsing (multiple kinds)
        if line.hasPrefix("OK ") {

            // 2a) VENOM OK lines
            if line.contains("VENOM") {
                parseOkVenomLine(line)
                return
            }

            // 2b) STOP line
            if line == "OK STOP" {
                // STOP means: everything is off; venom is definitely not running.
                isVenomRunning = false
                statusMessage = "Stopped (OK STOP)."
                return
            }

            // 2c) Verified PWM config line (ONLY if it has all three)
            //     This prevents "OK VENOM ON F=..." from being mistaken as config.
            if line.contains("F=") && line.contains("D=") && line.contains("A=") {
                parseOkPwmConfigLine(line)
                return
            }

            // Other OK lines: keep log only.
            statusMessage = "Arduino OK."
            return
        }

        // 3) ERR parsing
        if line.hasPrefix("ERR") {
            statusMessage = "Arduino error: \(line)"
            appendLog("[ERROR] Arduino: \(line)")
            return
        }

        // 4) Everything else: leave as log-only.
    }

    // =============================================================
    // MARK: - Parse: MODE <name>
    // =============================================================
    //
    // Example:
    //   MODE VENOM
    //
    private func parseModeLine(_ line: String) {
        // Simple split: "MODE" + name
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            nanoModeString = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "Nano mode: \(nanoModeString)"

            // If Nano says MODE is not VENOM, we can safely clear venom flag.
            // (Firmware truth wins.)
            if nanoModeString != "VENOM" {
                isVenomRunning = false
            }
        } else {
            nanoModeString = "UNKNOWN"
        }
    }

    // =============================================================
    // MARK: - Parse: OK VENOM ...
    // =============================================================
    //
    // Accepts both old and new firmware responses:
    //   Old:
    //     OK VENOM ON T_ON=2000 T_OFF=4000
    //
    //   New (paper-aligned):
    //     OK VENOM ON F=400.000 T_ON=4000 T_OFF=4000
    //
    // Also accepts:
    //     OK VENOM OFF
    //
    private func parseOkVenomLine(_ line: String) {

        // OFF case (very simple)
        if line.contains("VENOM OFF") {
            isVenomRunning = false
            statusMessage = "VENOM OFF."
            return
        }

        // ON case
        if line.contains("VENOM ON") {
            isVenomRunning = true
            statusMessage = "VENOM ON."

            // Pull out tokens like F=, T_ON=, T_OFF=
            let tokens = line.split(separator: " ")

            for token in tokens {
                if token.hasPrefix("F=") {
                    lastVenomFrequencyHz = Double(token.dropFirst(2))
                } else if token.hasPrefix("T_ON=") {
                    lastVenomOnMs = Int(token.dropFirst(5)) // after "T_ON="
                } else if token.hasPrefix("T_OFF=") {
                    lastVenomOffMs = Int(token.dropFirst(6)) // after "T_OFF="
                }
            }

            return
        }

        // If it’s some weird VENOM OK format, don’t crash—just log.
    }

    // =============================================================
    // MARK: - Parse: OK F=... D=... A=...  (Verified PWM config)
    // =============================================================
    //
    // Example:
    //   OK F=1000.000 D=50.000 A=1.000
    //
    private func parseOkPwmConfigLine(_ line: String) {
        let tokens = line.split(separator: " ")

        var freq: Double?
        var duty: Double?
        var amp: Double?

        for token in tokens {
            if token.hasPrefix("F=") {
                freq = Double(token.dropFirst(2))
            } else if token.hasPrefix("D=") {
                duty = Double(token.dropFirst(2))
            } else if token.hasPrefix("A=") {
                amp = Double(token.dropFirst(2))
            }
        }

        if let f = freq, let d = duty, let a = amp {
            lastVerifiedConfiguration = VerifiedConfiguration(
                frequencyHz: f,
                dutyCyclePercent: d,
                amplitude: a,
                timestamp: Date()
            )
            statusMessage = "Arduino verified PWM settings."
            appendLog("[INFO] Verified configuration updated.")
        } else {
            appendLog("[WARN] Could not parse OK PWM config line fully.")
        }
    }
}
