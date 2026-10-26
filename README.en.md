# OpenLidarFocus · DJI FM03

**Use iPhone LiDAR to focus a manual lens, or turn your phone into a wireless focus handwheel.**

[简体中文](README.md) | English

[Features](#features) · [Hardware and wiring](#hardware-and-wiring) · [Getting started](#getting-started) · [Development and testing](#development-and-testing)

OpenLidarFocus is an external lens focus project powered by iPhone LiDAR. An ESP32-S3 and CAN transceiver control a DJI RS Focus Motor (2022, FM03), adding distance-driven autofocus to a manual lens fitted with a focus gear ring. It also provides an independent wireless manual focus mode. The iPhone handles ranging, preview, and controls; the motor drives the external lens focus ring.

Current versions: **App 2.6.2+26 · ESP32 firmware 2.1.1 · UDP protocol v2**. The project is under active development and hardware validation. Supported hardware and features are listed below.

## Features

### LiDAR autofocus

- Rear iPhone LiDAR ranging with tap-to-select measurement and optional face tracking.
- Lens profiles store names, notes, focus direction, and distance calibration points. The lens library shows setup guidance and calibration status.
- **At least five calibration points** spanning near, middle, and far distances; add more afterward. Distances less than 2 cm apart update an existing point.
- **Piecewise interpolation in reciprocal distance (1/distance)** drives both the chart and focus targets. Measurements outside the calibrated range clamp to the nearest calibrated endpoint; invalid or stale measurements exit automatic mode.
- Portrait and landscape preview, composition grid, and an expandable control and calibration panel.

### Phone handwheel and A/B focus pulls

- Independent manual mode needs a connected device and completed FM03 limit calibration, without LiDAR or a lens distance table.
- Rotate the wheel rim, drag vertically in the center for fine adjustments, or switch to a slider for absolute 0–100% travel targets.
- Handwheel sensitivity of 0.25 / 0.5 / 1 / 2× and direction reversal. The slider shows orange A and blue B markers with position percentages.
- Set, reset, or clear A/B points, constrain travel between them, jump to endpoints, or run **0.5–8 second** timed focus pulls with eased or linear target curves.
- Three tick haptic styles and arrival haptics confirmed by actual feedback. Controls and the stop button stay visible while settings scroll separately.

A/B points come from stationary motor feedback and last only for the current limit-calibration session. Pull duration describes the target trajectory; actual mechanical arrival time depends on motor response.

### Devices, tuning, and protection

- ESP32 access point, UDP discovery, connection status, and a remembered device for reconnection attempts after app launch.
- Adjust maximum wheel command, startup acceleration, approach deceleration, and position tolerance. Changes require device readback confirmation, work during ordinary motion, and persist on the device after stopping.
- CAN diagnostics show motor stage, raw position, feedback age, transmit failures, and dropped receive frames.
- OLED shows firmware, hotspot, password, and IP for a full six seconds at startup, then trusted position, target, CAN/control links, and faults.
- Stopping ordinary focus control latches a lock and disables motion until an explicit reset. Backgrounding stops control and capture; returning requires an explicit reset before motion resumes.
- System, light, and dark appearance options, with the selection saved on iPhone.

## How it works

```text
iPhone LiDAR / selected target / face tracking
                     ↓
Swift FollowFocusCore ←→ Flutter UI / phone handwheel
ranging, lens mapping, session       ff.core channels
                     ↓ Wi-Fi / UDP v2
ESP32-S3: feedback position control, timeouts, OLED
                     ↕ CAN at 1 Mbps
                DJI FM03 → lens focus ring
```

The Swift core depends only on Foundation. The iOS shell handles the camera, LiDAR, and platform channels; Flutter handles presentation and user input. Motor position control runs in ESP32 firmware. **Coordinates 0–4096 represent normalized travel after FM03 limit calibration, not angles or step pulses. Speed settings are not RPM.**

## Hardware and wiring

- Automatic mode: an iPhone with rear LiDAR. Full iOS builds and deployment require macOS, Xcode, Flutter, and device signing. The current deployment target is iOS 15.4; LiDAR availability still depends on hardware.
- ESP32-S3 Super Mini with 4 MB Flash; SSD1306 72×40 I²C OLED.
- DJI RS Focus Motor (2022, FM03) and a suitable lens gear and mounting arrangement.
- SN65HVD230 or another 3.3 V logic CAN transceiver supporting 1 Mbps; an independent 5 V supply for FM03.

Wiring overview:

- GPIO4 → CAN transceiver D/TXD; GPIO5 ← R/RXD.
- OLED SDA → GPIO8, SCL → GPIO9; address detection supports `0x3C` / `0x3D`.
- Connect ESP32, transceiver, and motor supply grounds. Wire CANH/CANL using the verified FM03 breakout pinout.
- Disconnect RS3. Use 120 Ω termination at each bus end, approximately 60 Ω across CANH/CANL with power off.

The Type-C connection carries power and adapted CAN wiring here; ordinary USB wire colors do not establish the pinout. See the [hardware guide](HANDOFF.md) for complete wiring, power, and acceptance instructions.

When upgrading from the earlier TMC2209 design, remove the old STEP/DIR driver wiring first: GPIO5 is now CAN RX. Historical files in `docs/legacy/` do not describe current wiring.

## Getting started

1. Wire the hardware and power FM03 independently. Connect the phone to `FF-XXXXXX`, default password `change-me`. The default device address is `192.168.4.1`, UDP port `4210`.
2. Open device management from the app home page, discover and select a protocol v2 device, then connect. Grant local network access when prompted; automatic mode also needs camera permission.
3. Choose a mode and run **FM03 automatic limit calibration**, waiting for internal stages 1/2 → 3. Repeat after reconnecting, restarting the app, or changing lenses.
4. **Manual focus:** test with the wheel or slider, set A/B points after the motor stops, and optionally enable range limits or timed pulls.
5. **Automatic focus:** create or select a lens, make small test moves, and confirm which direction focuses nearer. Focus manually using the camera image, then record at least five points while the motor is stationary. Enter distance manually or use a fresh LiDAR measurement. Finish setup and enable autofocus.

Lens direction and distance tables persist, and limit recalibration preserves the table. Recalibrate after changing direction or gear mounting. Earlier TMC2209 calibration data cannot be reused directly for FM03.

**There is currently no verified software command to cancel FM03's internal autonomous limit calibration.** Stopping observation, software STOP, or disabling ordinary control cannot guarantee that this internal motion stops. Cut motor power if it must be stopped immediately. The ordinary focus stop/reset lock does not cancel this internal action.

## Development and testing

Install Flutter, Xcode, and PlatformIO first. Configure a development signing team in Xcode to run on an iPhone.

```sh
git clone https://github.com/ndpyzwy-0w0/OLF-OpenLidarFocus.git
cd OLF-OpenLidarFocus
flutter pub get
flutter run -d <iphone-device-id>
```

Run static checks, UI tests, and Swift core tests:

```sh
flutter analyze
flutter test
(cd ios/FollowFocusCore && swift test)
```

Build and flash ESP32 firmware:

```sh
pio run -d firmware
pio run -d firmware -t upload --upload-port <serial-port>
```

On macOS, preview the interface without hardware using Flutter, Python 3, and a Bash environment:

```sh
bash tool/ui_preview.sh
```

The preview uses demo data without real LiDAR, UDP, or CAN. The iOS simulator cannot validate LiDAR; the Android scaffold does not indicate complete hardware support. See [test/firmware_host/README.md](test/firmware_host/README.md) for firmware host simulation.

Repository layout:

```text
ios/FollowFocusCore/  Swift protocol, UDP, lens mapping, session core and tests
ios/Runner/           iOS camera / LiDAR, native preview, Flutter channels
lib/                  Flutter home, lens library, autofocus, phone handwheel
firmware/             ESP32-S3 CAN firmware and Python diagnostic tools
test/                 Flutter tests and firmware host simulation
tool/                 Web preview and timestamped serial capture
docs/legacy/          Historical TMC2209 design and protocol v1
```

## Validation scope and documentation

The project includes Swift core tests, Flutter UI tests, and firmware host simulation. Software tests and builds cannot replace mechanical acceptance: check lens load, backlash, repeatable positioning, actual focus accuracy, phone haptics, and face tracking in portrait and both landscape orientations with your installed hardware. Feedback and communication timeout protections apply to ordinary control; internal calibration has the limitation described above.

- [Hardware and validation](HANDOFF.md): wiring, build/deployment, and acceptance steps.
- [PROTOCOL.md](PROTOCOL.md): App ↔ ESP32 UDP v2 wire contract.
- [CONTROL_ARCHITECTURE.md](CONTROL_ARCHITECTURE.md): feedback control, coordinates, sessions, and stop behavior.
- [UI_DEV.md](UI_DEV.md): UI boundaries, demo preview, and tests.
- [LIDAR_INTERFACE.md](LIDAR_INTERFACE.md): native LiDAR sampling and event interface.

## Acknowledgments

FM03 CAN messages and feedback decoding are based on [DJI-FM03-can](https://github.com/ndpyzwy-0w0/DJI-FM03-can). The reference revision is recorded in the [hardware guide](HANDOFF.md#来源).
