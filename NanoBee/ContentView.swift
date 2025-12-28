//
//  ContentView.swift
//  NanoBee
//
//  Created by Stanley Benoit on 12/10/25.
//
//  NanoBee: macOS app to communicate with an Arduino Nano over USB serial.
//  Serial I/O is handled by SerialManager (SerialCore.swift).
//
//  =====================================================================
//  CHANGE LOG (timestamped so we can track growth)
//  =====================================================================
//
//  2025-12-10  - BASE
//              - Initial SwiftUI layout for NanoBee.
//
//  2025-12-22  - CHANGE
//              - SerialPort/SerialManager extracted (SerialCore.swift).
//              - ContentView delegates serial operations to SerialManager.
//
//  2025-12-26  - CHANGE
//              - Layout hardening for small windows:
//                  * Put ALL content inside ONE ScrollView.
//                  * Give log a fixed height so it scrolls (doesn't push UI off-screen).
//              - Added Link LED indicator in “Serial Connection” box:
//                  * Green = serialManager.isLinkAlive == true
//                  * Red   = serialManager.isLinkAlive == false
//
//  2025-12-26  - DOCS (COMMENT CONSISTENCY PASS)
//              - Standardized all MARK headers with:
//                  * VARIABLES DEFINED IN THIS SECTION  (if we declare state here)
//                  * VARIABLES USED (READ-ONLY) IN THIS SECTION (if we only read state)
//              - Added beginner-friendly notes explaining SwiftUI redraw behavior.
//
//  2025-12-26  - CHANGE (MODE MUTUAL EXCLUSION / PANEL CLEARING)
//              - Added activePanel + switchActivePanel() in the app.
//              - When the user touches PWM vs DIGITAL vs POWER/GRID:
//                  1) App sends STOP (hardware safety).
//                  2) App clears the OTHER UI sections to safe defaults.
//                  3) App sends MODE (optional sync; Nano reports its mode).
//              - Added suppressSends guard so UI resets do NOT accidentally send serial.
//
//  2025-12-28  - CHANGE (VENOM UI BUTTONS + PAPER-ALIGNED PRESETS)
//              - Added “VENOM (paper-aligned)” controls inside PWM Tools panel.
//              - Adds:
//                  * Start VENOM button (sends SET then VENOM)
//                  * Stop button (sends STOP)
//                  * Preset frequency picker (200/400/800/1000 Hz)
//                  * Quick MODE/STATUS buttons
//              - Uses existing safety model: switchActivePanel(to: .pwm)
//                  -> sends STOP, clears other panels, then sends MODE.
//              - Start VENOM uses explicit manual lines so TX log shows exactly
//                what the host asked the Nano to do.
//
//  2025-12-28  - FIX (SERIALCORE INTEGRATION)
//              - Added a small “Nano Status Badge” to display firmware truth:
//                  * serialManager.nanoModeString
//                  * serialManager.isVenomRunning
//                  * lastVenomFrequencyHz / lastVenomOnMs / lastVenomOffMs
//              - This avoids “guessing” state from UI presses.
//              - If you did NOT merge the SerialCore.swift update I gave you,
//                the badge fields won’t exist and Xcode will error.
//                (So: merge SerialCore.swift first.)
//
//  =====================================================================
//  NASA “POWER OF 10” STYLE RULES (practical SwiftUI version)
//  =====================================================================
//
//  1) No recursion.
//  2) No infinite loops (SwiftUI is declarative; our own loops are bounded).
//  3) Bounded UI state: small @State values and simple dictionaries.
//  4) Validate before sending commands:
//       - Disable buttons when not connected.
//       - Guard suppressSends during programmatic resets.
//  5) Single source of truth for serial state: SerialManager.
//  6) Fail safe behavior:
//       - When switching panels, app sends STOP first.
//       - Firmware does hard-off on STOP.
//  7) One owner at a time:
//       - AppPanel mutual exclusion mirrors firmware MODE mutual exclusion.
//  8) “Hard off” means HARD OFF (firmware responsibility):
//       - disconnect timer output
//       - stop timer clock
//       - drive pin LOW (not floating)
//  9) State machines are explicit and readable:
//       - In app: panel switching + suppression logic is explicit.
// 10) Prefer simple, testable behavior over cleverness:
//       - VENOM buttons send plain-text commands you can see in the log.
//
//  =====================================================================
//  4-YEAR-OLD EXPLANATION (yes, really)
//  =====================================================================
//
//  - The Mac app is the “boss” that tells the Nano what to do.
//  - The Nano listens on a “talking wire” called USB serial.
//  - You press buttons.
//  - The app sends simple words like:
//
//        SET F=400 D=50 A=1
//        VENOM
//        STOP
//
//  - The Nano answers with words like:
//
//        OK ...
//        ERR ...
//        MODE VENOM
//
//  - When you touch PWM tools, we say “STOP!” first so nothing fights.
//

import SwiftUI
import Foundation

// =============================================================
// MARK: - UI: Main Window
// =============================================================
//
// VARIABLES USED (READ-ONLY) IN THIS SECTION
// - SerialManager: referenced by ContentView via @EnvironmentObject.
// - SwiftUI framework types: View, GroupBox, Picker, Button, Toggle, etc.
//

struct ContentView: View {

    // =============================================================
    // MARK: - Shared Model Object (Serial Manager)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - serialManager: SerialManager (@EnvironmentObject)
    //
    @EnvironmentObject private var serialManager: SerialManager

    // =============================================================
    // MARK: - User Input State (PWM + Manual Command)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - frequencyBaseHz: Double (@State)
    // - frequencyScaleExponent: Int (@State)
    // - dutyCyclePercent: Double (@State)
    // - amplitude: Double (@State)
    // - manualCommandText: String (@State)
    // - autoScrollEnabled: Bool (@State)
    //
    @State private var frequencyBaseHz: Double = 1000.0
    @State private var frequencyScaleExponent: Int = 0
    @State private var dutyCyclePercent: Double = 50.0
    @State private var amplitude: Double = 1.0
    @State private var manualCommandText: String = ""
    @State private var autoScrollEnabled: Bool = true

    // =============================================================
    // MARK: - VENOM UI State (paper-aligned presets)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - venomPresetHz: Double (@State)
    //
    @State private var venomPresetHz: Double = 400.0

    // =============================================================
    // MARK: - Digital Output UI State (DOUT D2..D6)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - digitalPinState: [Int: Bool] (@State)
    //
    @State private var digitalPinState: [Int: Bool] = [
        2: false, 3: false, 4: false, 5: false, 6: false
    ]

    // =============================================================
    // MARK: - POWER / GRID VOLTAGE UI STATE (VSET)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - selectedVsetVoltage: Int (@State)
    // - vsetEnableRequested: Bool (@State)
    //
    @State private var selectedVsetVoltage: Int = 0
    @State private var vsetEnableRequested: Bool = false

    // =============================================================
    // MARK: - MODE / PANEL SELECTION (UI mutual exclusion)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - activePanel: AppPanel (@State)
    // - suppressSends: Bool (@State)
    //
    private enum AppPanel: String {
        case pwm
        case digital
        case powerGrid
        case none
    }

    @State private var activePanel: AppPanel = .none
    @State private var suppressSends: Bool = false

    // =============================================================
    // MARK: - Local Constants (UI-only)
    // =============================================================
    //
    // VARIABLES DEFINED IN THIS SECTION
    // - maxScaleExponent / minScaleExponent: Int
    //
    private let maxScaleExponent: Int = 3   // x1000
    private let minScaleExponent: Int = 0   // x1

    // =============================================================
    // MARK: - Derived Values (Computed Properties)
    // =============================================================
    //
    // VARIABLES USED (READ-ONLY) IN THIS SECTION
    // - frequencyBaseHz, frequencyScaleExponent
    //
    private var effectiveFrequencyHz: Double {
        frequencyBaseHz * pow(10.0, Double(frequencyScaleExponent))
    }

    // =============================================================
    // MARK: - Panel Switching + UI Reset Helpers (safety)
    // =============================================================

    private func resetDigitalUIToSafe()
    {
        for pin in [2,3,4,5,6] {
            digitalPinState[pin] = false
        }
    }

    private func resetVsetUIToSafe()
    {
        selectedVsetVoltage = 0
        vsetEnableRequested = false
    }

    private func resetPwmUIToSafe()
    {
        // We keep typed values (frequency/duty/amplitude).
        // This is a “UI safety reset” not a “memory erase”.
    }

    private func switchActivePanel(to newPanel: AppPanel)
    {
        guard newPanel != activePanel else { return }

        // SAFETY STEP 1:
        // Tell the Nano to STOP before we do anything else.
        serialManager.sendManualCommandLine("STOP")

        // SAFETY STEP 2:
        // Reset the UI panels we are NOT using, without sending serial.
        suppressSends = true
        defer { suppressSends = false }

        switch newPanel {
        case .digital:
            resetVsetUIToSafe()
            resetPwmUIToSafe()

        case .powerGrid:
            resetDigitalUIToSafe()
            resetPwmUIToSafe()

        case .pwm:
            resetDigitalUIToSafe()
            resetVsetUIToSafe()

        case .none:
            resetDigitalUIToSafe()
            resetVsetUIToSafe()
            resetPwmUIToSafe()
        }

        activePanel = newPanel

        // SAFETY STEP 3 (optional but helpful):
        // Ask the Nano what MODE it thinks it is in.
        serialManager.sendManualCommandLine("MODE")
    }

    // =============================================================
    // MARK: - Digital Helpers (talk to Nano)
    // =============================================================

    private func sendDigital(pin: Int, value: Bool)
    {
        guard !suppressSends else { return }
        switchActivePanel(to: .digital)
        serialManager.sendManualCommandLine("DOUT \(pin) \(value ? 1 : 0)")
    }

    // =============================================================
    // MARK: - POWER PANEL HELPERS (talk to Nano)
    // =============================================================

    private func vsetSendOff() {
        guard !suppressSends else { return }
        switchActivePanel(to: .powerGrid)

        serialManager.sendManualCommandLine("VSET OFF")
        selectedVsetVoltage = 0
        vsetEnableRequested = false
    }

    private func vsetSendSelectOnly(voltage: Int) {
        guard !suppressSends else { return }
        switchActivePanel(to: .powerGrid)

        serialManager.sendManualCommandLine("VSET \(voltage)")
        selectedVsetVoltage = voltage
        vsetEnableRequested = false
    }

    private func vsetSendSelectAndEnable(voltage: Int) {
        guard !suppressSends else { return }
        switchActivePanel(to: .powerGrid)

        guard voltage != 0 else {
            vsetSendOff()
            return
        }
        serialManager.sendManualCommandLine("VSET \(voltage) ON")
        selectedVsetVoltage = voltage
        vsetEnableRequested = true
    }

    private func vsetSendDisableOnly(voltage: Int) {
        guard !suppressSends else { return }
        switchActivePanel(to: .powerGrid)

        guard voltage != 0 else {
            vsetSendOff()
            return
        }
        serialManager.sendManualCommandLine("VSET \(voltage) OFF")
        selectedVsetVoltage = voltage
        vsetEnableRequested = false
    }

    // =============================================================
    // MARK: - VENOM Helpers (talk to Nano)
    // =============================================================

    private func startVenomPaperAligned()
    {
        guard !suppressSends else { return }
        guard serialManager.isConnected else { return }

        // Claim PWM panel (STOP + clear others + MODE query)
        switchActivePanel(to: .pwm)

        // Paper-aligned starter values.
        // (Firmware will clamp again; we still send clean values.)
        let f = venomPresetHz
        let d = 50.0
        let a = 1.0

        // Explicit manual lines so the TX log is crystal clear.
        serialManager.sendManualCommandLine(String(format: "SET F=%.3f D=%.3f A=%.3f", f, d, a))
        serialManager.sendManualCommandLine("VENOM")
    }

    private func stopVenom()
    {
        guard !suppressSends else { return }
        guard serialManager.isConnected else { return }
        serialManager.sendManualCommandLine("STOP")
    }

    // =============================================================
    // MARK: - Small UI helper: Nano status badge text
    // =============================================================
    //
    // VARIABLES USED (READ-ONLY) IN THIS SECTION
    // - serialManager.nanoModeString
    // - serialManager.isVenomRunning
    // - serialManager.lastVenomFrequencyHz / lastVenomOnMs / lastVenomOffMs
    //
    private var nanoBadgeLine: String {
        // Safe formatting without force-unwrapping.
        let mode = serialManager.nanoModeString
        let venom = serialManager.isVenomRunning ? "ON" : "OFF"

        let fText: String
        if let f = serialManager.lastVenomFrequencyHz {
            fText = String(format: "%.0fHz", f)
        } else {
            fText = "F=?"
        }

        let onText: String
        if let onMs = serialManager.lastVenomOnMs {
            onText = "\(onMs)ms"
        } else {
            onText = "ON=?"
        }

        let offText: String
        if let offMs = serialManager.lastVenomOffMs {
            offText = "\(offMs)ms"
        } else {
            offText = "OFF=?"
        }

        return "Nano: MODE=\(mode)  VENOM=\(venom)  \(fText)  T_ON=\(onText)  T_OFF=\(offText)"
    }

    // =============================================================
    // MARK: - Body (SwiftUI Layout)
    // =============================================================

    var body: some View {

        ZStack(alignment: .topTrailing) {

            ScrollView {

                VStack(alignment: .leading, spacing: 22.0) {

                    Text("NanoBee")
                        .font(.title)
                        .padding(.top, 8.0)

                    Spacer()

                    // =====================================================
                    // MARK: - Serial Connection UI
                    // =====================================================
                    GroupBox(label: Text("Serial Connection")) {

                        VStack(alignment: .leading, spacing: 8.0) {

                            HStack {
                                Text("Port:")

                                Picker("Port", selection: $serialManager.selectedPortPath) {
                                    ForEach(serialManager.availablePorts, id: \.self) { portPath in
                                        Text(portPath).tag(portPath)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 380.0)

                                Button("Refresh") {
                                    serialManager.refreshAvailablePorts()
                                }
                                .help("Rescan /dev for USB serial devices.")
                            }

                            HStack(spacing: 12) {

                                Text("Baud Rate:")

                                Picker("Baud Rate", selection: $serialManager.baudRate) {
                                    ForEach(serialManager.supportedBaudRates, id: \.self) { rate in
                                        Text("\(rate)").tag(rate)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)

                                Spacer()

                                // LINK LED
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(serialManager.isLinkAlive ? Color.green : Color.red)
                                        .frame(width: 12, height: 12)
                                        .overlay(
                                            Circle().stroke(Color.black.opacity(0.25), lineWidth: 1)
                                        )

                                    Text(serialManager.isLinkAlive ? "Alive" : "Dead")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .help("Green = receiving lines from Nano. Red = disconnected or timed out.")

                                if serialManager.isConnected {
                                    Button("Disconnect") {
                                        serialManager.disconnect()
                                    }
                                    .keyboardShortcut(.cancelAction)
                                } else {
                                    Button("Connect") {
                                        serialManager.connect()
                                    }
                                    .keyboardShortcut(.defaultAction)
                                }
                            }

                            Text("Status: \(serialManager.statusMessage)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 4.0)
                        }
                        .padding(8.0)
                    }

                    // =====================================================
                    // MARK: - PWM Configuration UI
                    // =====================================================
                    HStack(alignment: .top, spacing: 16) {

                        GroupBox(label: Text("PWM Configuration")) {
                            VStack(alignment: .leading, spacing: 12.0) {

                                // FREQUENCY
                                VStack(alignment: .leading, spacing: 4.0) {
                                    HStack {
                                        Text("Frequency:")
                                        Spacer()
                                        Text(String(format: "%.3f Hz", effectiveFrequencyHz))
                                            .monospacedDigit()
                                    }

                                    HStack(spacing: 12.0) {
                                        VStack(alignment: .leading, spacing: 2.0) {
                                            Text("Base:")
                                            TextField("Base frequency",
                                                      value: $frequencyBaseHz,
                                                      format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 100)
                                        }

                                        VStack(alignment: .leading, spacing: 2.0) {
                                            Text("Scale:")
                                            Text("x\(Int(pow(10.0, Double(frequencyScaleExponent))))")
                                                .font(.caption)
                                        }

                                        HStack(spacing: 6.0) {
                                            Button("x1")   { frequencyScaleExponent = 0 }
                                            Button("x10")  { frequencyScaleExponent = 1 }
                                            Button("x100") { frequencyScaleExponent = 2 }
                                            Button("x1k")  { frequencyScaleExponent = 3 }
                                        }
                                    }
                                }

                                // DUTY
                                VStack(alignment: .leading, spacing: 4.0) {
                                    Text("Duty Cycle (%):")
                                    HStack {
                                        TextField("Duty",
                                                  value: $dutyCyclePercent,
                                                  format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 80)

                                        Text(String(format: "%.1f %%", dutyCyclePercent))
                                            .monospacedDigit()
                                    }
                                }

                                // AMPLITUDE
                                VStack(alignment: .leading, spacing: 4.0) {
                                    Text("Amplitude:")
                                    TextField("Amplitude",
                                              value: $amplitude,
                                              format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }

                                Divider()

                                Button("Send Configuration") {
                                    guard !suppressSends else { return }
                                    switchActivePanel(to: .pwm)

                                    serialManager.sendConfiguration(
                                        frequencyHz: effectiveFrequencyHz,
                                        dutyCyclePercent: dutyCyclePercent,
                                        amplitude: amplitude
                                    )
                                }
                                .disabled(!serialManager.isConnected)

                            }
                            .padding(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        // =====================================================
                        // MARK: - PWM Tools (VENOM Buttons live here)
                        // =====================================================
                        GroupBox(label: Text("PWM Tools")) {
                            VStack(alignment: .leading, spacing: 10) {

                                // ---- Nano truth badge ----
                                // This uses SerialManager’s parsed RX lines.
                                // It shows what the Nano says, not what we *think*.
                                Text(nanoBadgeLine)
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)

                                Divider()

                                Text("VENOM (paper-aligned)")
                                    .font(.headline)

                                Text("Start sends SET then VENOM. STOP halts everything safely.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Picker("Preset", selection: $venomPresetHz) {
                                    Text("200 Hz").tag(200.0)
                                    Text("400 Hz (default)").tag(400.0)
                                    Text("800 Hz").tag(800.0)
                                    Text("1000 Hz").tag(1000.0)
                                }
                                .pickerStyle(.segmented)
                                .disabled(!serialManager.isConnected)
                                .onChange(of: venomPresetHz) { _, _ in
                                    // Touching PWM tools claims PWM panel.
                                    guard !suppressSends else { return }
                                    switchActivePanel(to: .pwm)
                                }

                                HStack(spacing: 10) {
                                    Button("Start VENOM") {
                                        startVenomPaperAligned()
                                    }
                                    .disabled(!serialManager.isConnected)

                                    Button("Stop") {
                                        stopVenom()
                                    }
                                    .disabled(!serialManager.isConnected)
                                }

                                Divider()

                                Text("Quick checks")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 10) {
                                    Button("MODE") {
                                        guard !suppressSends else { return }
                                        serialManager.sendManualCommandLine("MODE")
                                    }
                                    .disabled(!serialManager.isConnected)

                                    Button("STATUS") {
                                        guard !suppressSends else { return }
                                        serialManager.sendManualCommandLine("STATUS")
                                    }
                                    .disabled(!serialManager.isConnected)
                                }

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .padding(8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    // =====================================================
                    // MARK: - Digital Outputs + VSET UI
                    // =====================================================
                    HStack(alignment: .top, spacing: 16) {

                        GroupBox(label: Text("Digital Outputs (LED Test)")) {
                            VStack(alignment: .leading, spacing: 8) {

                                Text("Toggle D2–D6. (LED + resistor to GND)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                ForEach([2,3,4,5,6], id: \.self) { pin in
                                    PinToggleRow(
                                        pin: pin,
                                        isOn: Binding(
                                            get: { digitalPinState[pin] ?? false },
                                            set: { newValue in
                                                if suppressSends {
                                                    digitalPinState[pin] = newValue
                                                    return
                                                }

                                                switchActivePanel(to: .digital)

                                                digitalPinState[pin] = newValue
                                                sendDigital(pin: pin, value: newValue)
                                            }
                                        ),
                                        enabled: serialManager.isConnected
                                    ) {
                                        guard !suppressSends else { return }
                                        switchActivePanel(to: .digital)

                                        let next = !(digitalPinState[pin] ?? false)
                                        digitalPinState[pin] = next
                                        sendDigital(pin: pin, value: next)
                                    }
                                }

                                HStack {
                                    Spacer()
                                    Button("All Off") {
                                        guard !suppressSends else { return }
                                        switchActivePanel(to: .digital)

                                        for pin in [2,3,4,5,6] {
                                            digitalPinState[pin] = false
                                            serialManager.sendManualCommandLine("DOUT \(pin) 0")
                                        }
                                    }
                                    .disabled(!serialManager.isConnected)
                                }
                            }
                            .padding(8)
                        }
                        .frame(width: 280)

                        GroupBox(label: Text("Power / Grid Voltage")) {
                            VStack(alignment: .leading, spacing: 10) {

                                Text("Pick a voltage, then enable output.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Picker("Voltage", selection: $selectedVsetVoltage) {
                                    Text("OFF").tag(0)
                                    Text("12 V").tag(12)
                                    Text("15 V").tag(15)
                                    Text("18 V").tag(18)
                                    Text("24 V").tag(24)
                                    Text("30 V").tag(30)
                                }
                                .pickerStyle(.radioGroup)
                                .disabled(!serialManager.isConnected)
                                .onChange(of: selectedVsetVoltage) { _, newValue in
                                    guard !suppressSends else { return }

                                    if newValue == 0 {
                                        vsetSendOff()
                                    } else {
                                        vsetSendSelectOnly(voltage: newValue)
                                    }
                                }

                                Divider()

                                Toggle(isOn: $vsetEnableRequested) {
                                    Text("Enable Output")
                                        .font(.headline)
                                }
                                .toggleStyle(.switch)
                                .disabled(!serialManager.isConnected || selectedVsetVoltage == 0)
                                .onChange(of: vsetEnableRequested) { _, isOn in
                                    guard !suppressSends else { return }

                                    if isOn {
                                        vsetSendSelectAndEnable(voltage: selectedVsetVoltage)
                                    } else {
                                        vsetSendDisableOnly(voltage: selectedVsetVoltage)
                                    }
                                }

                                HStack {
                                    Spacer()
                                    Button("Power OFF") {
                                        guard !suppressSends else { return }
                                        vsetSendOff()
                                    }
                                    .disabled(!serialManager.isConnected)
                                }

                                Text("Requested: \(selectedVsetVoltage == 0 ? "OFF" : "\(selectedVsetVoltage)V")  |  EN=\(vsetEnableRequested ? "ON" : "OFF")")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .padding(8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    // =====================================================
                    // MARK: - Serial Log + Manual Command UI
                    // =====================================================
                    GroupBox(label: Text("Serial Log (RX / TX / INFO)")) {
                        VStack(alignment: .leading, spacing: 8.0) {

                            ScrollView {
                                Text(serialManager.logText.isEmpty ? "No log messages yet." : serialManager.logText)
                                    .font(.system(size: 11.0, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(4.0)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 200)
                            .background(Color(NSColor.textBackgroundColor))
                            .border(Color.gray.opacity(0.4))

                            VStack(alignment: .leading, spacing: 4.0) {
                                Text("Manual Serial Command:")
                                    .font(.caption)

                                HStack {
                                    TextField("Type a command to send over serial", text: $manualCommandText)
                                        .textFieldStyle(.roundedBorder)

                                    Button("Send Manual") {
                                        serialManager.sendManualCommandLine(manualCommandText)
                                        manualCommandText = ""
                                    }
                                    .disabled(!serialManager.isConnected)
                                }
                                .help("Type any line (e.g. 'HELP') then click 'Send Manual'.")
                            }

                            HStack {
                                Spacer()
                                Button("Clear Log") {
                                    serialManager.clearLog()
                                }
                            }
                        }
                        .padding(8.0)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .task {
                serialManager.refreshAvailablePorts()
            }

            Image("BeeCorner")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .padding(1)
        }
    }
}

// =============================================================
// MARK: - Preview
// =============================================================

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SerialManager())
            .frame(width: 1000.0, height: 650.0)
    }
}
