# BLE background capability

The Chessnut Air requires the app target to include the iOS background mode:

- `UIBackgroundModes`
- `bluetooth-central`

This capability must be enabled in the target Signing & Capabilities tab or the generated Info.plist before relying on background CoreBluetooth restoration.
