import SwiftUI

@main
struct BitSwitchApp: App {
    @StateObject private var engine: SwitchEngine = {
        let e = SwitchEngine()
        e.start()
        return e
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            Text(menuBarLabel)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarLabel: String {
        if !engine.isEnabled {
            return "⏸ BitSwitch"
        }
        if let format = engine.currentSourceFormat {
            return format.shortLabel
        }
        if engine.playerDetected {
            return "▶ —"
        }
        return "BitSwitch"
    }
}

struct MenuBarView: View {
    @ObservedObject var engine: SwitchEngine
    @State private var newPlayerName = ""

    var body: some View {
        Section {
            if let file = engine.currentFile {
                Text("♫ \(file)")
                if let player = engine.currentPlayer {
                    Text("Player: \(player)")
                        .foregroundStyle(.secondary)
                }
            } else if engine.playerDetected {
                Text("No audio file playing")
            } else {
                Text("No player running")
            }

            if let src = engine.currentSourceFormat {
                Text("Source: \(src.description)")
            }

            if let dev = engine.currentDeviceFormat {
                Text("Device: \(dev.description)")
            }

            if let msg = engine.lastSwitchMessage {
                Text(msg)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        Section {
            Text("Output: \(engine.deviceName)")
                .font(.headline)

            Menu("Change Device") {
                ForEach(AudioDeviceManager.allOutputDevices(), id: \.id) { device in
                    Button(device.name) {
                        engine.selectDevice(device)
                    }
                }
            }
        }

        Divider()

        Section {
            Toggle("Auto-Switch", isOn: $engine.isEnabled)
        }

        if !engine.customPlayers.isEmpty {
            Divider()
            Menu("Custom Players") {
                ForEach(Array(engine.customPlayers).sorted(), id: \.self) { name in
                    Button("Remove \(name)") {
                        engine.removeCustomPlayer(name)
                    }
                }
            }
        }

        Divider()

        Button("Quit BitSwitch") {
            engine.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
