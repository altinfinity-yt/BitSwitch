import Foundation
import Darwin

enum ProcessMonitor {
    static let defaultPlayers: Set<String> = [
        "foobar2000",
        "vlc",
        "swinsian",
        "audirvana",
        "vox",
        "decibel",
        "colibri",
        "iina",
        "mpv",
        "cog",
        "amarra",
        "jriver",
    ]

    static func findPlayerPIDs(players: Set<String> = defaultPlayers) -> [(pid: pid_t, name: String)] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let pidCount = Int(bufferSize) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: pidCount)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.stride

        var nameBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var found: [(pid: pid_t, name: String)] = []

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            let nameLower = name.lowercased()

            for player in players {
                if nameLower.contains(player.lowercased()) {
                    found.append((pid: pid, name: name))
                    break
                }
            }
        }
        return found
    }

    static func openAudioFiles(forPID pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let fdCount = Int(bufferSize) / fdInfoSize
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, bufferSize)
        let actualCount = Int(actualSize) / fdInfoSize

        var audioPaths: [String] = []

        for i in 0..<actualCount {
            let fd = fdInfos[i]
            guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { continue }

            var vnodeInfo = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            let result = proc_pidfdinfo(
                pid,
                fd.proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &vnodeInfo,
                infoSize
            )
            guard result > 0 else { continue }

            let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                    String(cString: cstr)
                }
            }

            let ext = (path as NSString).pathExtension.lowercased()
            if AudioFileParser.supportedExtensions.contains(ext) {
                audioPaths.append(path)
            }
        }

        return audioPaths
    }

    static func currentlyPlayingFile(players: Set<String> = defaultPlayers) -> (path: String, player: String)? {
        let runningPlayers = findPlayerPIDs(players: players)
        for p in runningPlayers {
            let files = openAudioFiles(forPID: p.pid)
            if let file = files.last {
                return (path: file, player: p.name)
            }
        }
        return nil
    }
}
