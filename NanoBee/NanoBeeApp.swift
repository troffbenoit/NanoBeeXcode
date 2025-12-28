//
//  NanoBeeApp.swift
//  NanoBee
//
//  Created by Stanley Benoit on 12/10/25.
//
//  NanoBee: macOS app to communicate with an Arduino Nano over USB serial.
//  Uses Darwin termios + POSIX APIs for serial I/O.
//

import SwiftUI
import AppKit   // needed for NSApp / standard About panel

@main
struct NanoBeeApp: App {

    @StateObject private var serialManager = SerialManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serialManager)
                .frame(minWidth: 800, minHeight: 600)
        }
        // Attach menu commands to this scene
        .commands {
            // Replace the default "About" item with one that shows
            // the standard macOS About panel.
            CommandGroup(replacing: .appInfo) {
                Button("About NanoBee") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
