import Foundation

@MainActor
final class SwitchEngine: ObservableObject {
    @Published var isEnabled = true
    @Published var currentFile: String?
    @Published var currentPlayer: String?
    @Published var currentSourceFormat: SourceFormat?
    @Published var currentDeviceFormat: AudioFormat?
    @Published var targetDevice: AudioDevice?
    @Published var playerDetected = false
    @Published var lastSwitchMessage: String?
    @Published var customPlayers: Set<String> = []

    private var pollTimer: Timer?
    private var lastSeenPath: String?
    private let pollInterval: TimeInterval = 1.0

    private var allPlayers: Set<String> {
        ProcessMonitor.defaultPlayers.union(customPlayers)
    }

    var deviceName: String {
        targetDevice?.name ?? "No device"
    }

    func start() {
        loadCustomPlayers()

        targetDevice = AudioDeviceManager.findDevice(nameContaining: "Volt")
            ?? AudioDeviceManager.defaultOutputDevice()

        if let dev = targetDevice {
            currentDeviceFormat = AudioDeviceManager.currentFormat(deviceID: dev.id)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func selectDevice(_ device: AudioDevice) {
        targetDevice = device
        currentDeviceFormat = AudioDeviceManager.currentFormat(deviceID: device.id)
    }

    func addCustomPlayer(_ name: String) {
        customPlayers.insert(name)
        saveCustomPlayers()
    }

    func removeCustomPlayer(_ name: String) {
        customPlayers.remove(name)
        saveCustomPlayers()
    }

    private func poll() {
        let runningPlayers = ProcessMonitor.findPlayerPIDs(players: allPlayers)
        playerDetected = !runningPlayers.isEmpty

        guard isEnabled, !runningPlayers.isEmpty else {
            if !playerDetected {
                currentFile = nil
                currentPlayer = nil
                currentSourceFormat = nil
            }
            return
        }

        // Check each running player for open audio files
        var found: (path: String, player: String)?
        for p in runningPlayers {
            let files = ProcessMonitor.openAudioFiles(forPID: p.pid)
            if let file = files.last {
                found = (path: file, player: p.name)
                break
            }
        }

        guard let result = found else {
            currentFile = nil
            currentSourceFormat = nil
            return
        }

        currentPlayer = result.player

        guard result.path != lastSeenPath else { return }
        lastSeenPath = result.path
        currentFile = (result.path as NSString).lastPathComponent

        guard let format = try? AudioFileParser.parse(path: result.path) else {
            lastSwitchMessage = "Failed to read file metadata"
            return
        }
        currentSourceFormat = format

        guard let device = targetDevice else {
            lastSwitchMessage = "No output device selected"
            return
        }

        let currentDev = AudioDeviceManager.currentFormat(deviceID: device.id)
        currentDeviceFormat = currentDev

        let needsSwitch = currentDev == nil
            || Int(currentDev!.sampleRate) != format.sampleRate
            || currentDev!.bitsPerChannel != format.bitsPerSample

        if needsSwitch {
            let success = AudioDeviceManager.switchFormat(
                deviceID: device.id,
                sampleRate: format.sampleRate,
                bitsPerChannel: format.bitsPerSample
            )

            if success {
                currentDeviceFormat = AudioDeviceManager.currentFormat(deviceID: device.id)
                lastSwitchMessage = "Switched to \(format)"
            } else {
                lastSwitchMessage = "Failed to switch to \(format)"
            }
        } else {
            lastSwitchMessage = "Already at \(format)"
        }
    }

    // MARK: - Persistence

    private var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BitSwitch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private func saveCustomPlayers() {
        let data = try? JSONEncoder().encode(Array(customPlayers))
        try? data?.write(to: configURL)
    }

    private func loadCustomPlayers() {
        guard let data = try? Data(contentsOf: configURL),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return }
        customPlayers = Set(names)
    }
}
