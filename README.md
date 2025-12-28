# NanoBeeXcode

NanoBeeXcode is a macOS SwiftUI application used to communicate with an Arduino Nano
over USB serial. It is intended for hardware bring-up, PWM testing, MOSFET and relay
control, and general embedded system experimentation.

This repository contains the full Xcode project and can be built directly on macOS.

---

## Features

- macOS app built with SwiftUI
- USB serial communication with Arduino Nano
- Live connection / link status
- Command-based interface (frequency, duty cycle, amplitude)
- Scrollable activity and log output
- Designed for lab testing and hardware validation

---

## Requirements

### Software
- macOS 13 or newer
- Xcode 15 or newer
- Git (optional, for cloning)

### Hardware
- Arduino Nano (or compatible)
- USB cable
- External power supply and test load (relay, lamp, MOSFET, etc.)

---

## Getting the Code

### Option 1: Download ZIP
1. Click **Code**
2. Select **Download ZIP**
3. Unzip the folder
4. Open `NanoBee.xcodeproj`

### Option 2: Clone with Git
```bash
git clone https://github.com/troffbenoit/NanoBeeXcode.git
cd NanoBeeXcode
open NanoBee.xcodeproj
