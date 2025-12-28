//
//  TogglePort.swift
//  NanoBee
//
//  Created by Stanley Benoit on 12/13/25.
//

import Foundation
import SwiftUI
import Combine

/// Small helper object that sends digital on/off commands to the Arduino.
/// It does NOT own the serial port; it just uses SerialManager's manual send.
final class TogglePortController: ObservableObject {

    /// Current on/off state for each pin (D2-D6).
    @Published var states: [Int: Bool] = [
        2: false,
        3: false,
        4: false,
        5: false,
        6: false
    ]

    /// Toggle the pin state and send command to Arduino.
    func toggle(pin: Int, serialManager: SerialManager) {
        let newValue = !(states[pin] ?? false)
        set(pin: pin, value: newValue, serialManager: serialManager)
    }

    /// Force a pin state and send command to Arduino.
    func set(pin: Int, value: Bool, serialManager: SerialManager) {
        states[pin] = value

        // Our command format (simple, line-based):
        // DOUT <pin> <0|1>
        let v = value ? 1 : 0
        serialManager.sendManualCommandLine("DOUT \(pin) \(v)")
    }
}

/// A simple "radio-looking" toggle button for one pin.
struct PinToggleRow: View {
    let pin: Int
    @Binding var isOn: Bool
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Radio-style indicator
            Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundColor(enabled ? (isOn ? .green : .secondary) : .gray)

            Text("D\(pin)")
                .frame(width: 38, alignment: .leading)

            Text(isOn ? "ON" : "OFF")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isOn ? .green : .secondary)

            Spacer()

            Button(isOn ? "Turn Off" : "Turn On") {
                onTap()
            }
            .disabled(!enabled)
        }
        .padding(.vertical, 4)
    }
}
