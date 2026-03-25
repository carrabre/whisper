import AppKit
import Foundation

enum AudioCue: String, CaseIterable {
    case recordingWillStart
    case recordingDidStop
    case pipelineDidComplete

    var systemSoundName: String {
        switch self {
        case .recordingWillStart, .recordingDidStop:
            return "Ping"
        case .pipelineDidComplete:
            return "Glass"
        }
    }

    var volume: Float {
        switch self {
        case .recordingWillStart, .recordingDidStop:
            return 0.4
        case .pipelineDidComplete:
            return 0.45
        }
    }
}

final class AudioCuePlayer {
    private let sounds: [AudioCue: NSSound]

    init(fileManager: FileManager = .default) {
        self.sounds = AudioCue.allCases.reduce(into: [:]) { loadedSounds, cue in
            guard let sound = Self.loadSound(named: cue.systemSoundName, fileManager: fileManager) else { return }
            sound.volume = cue.volume
            loadedSounds[cue] = sound
        }

        let loadedCues = sounds.keys.map(\.rawValue).sorted().joined(separator: ", ")
        DebugLog.log(
            "Audio cue player ready. loaded=\(loadedCues.isEmpty ? "none" : loadedCues)",
            category: "audio"
        )
    }

    func play(_ cue: AudioCue) {
        guard let sound = sounds[cue] else {
            DebugLog.log("Audio cue unavailable: \(cue.rawValue)", category: "audio")
            return
        }

        sound.stop()
        sound.volume = cue.volume

        if sound.play() {
            DebugLog.log("Played audio cue \(cue.rawValue)", category: "audio")
        } else {
            DebugLog.log("Audio cue failed to play: \(cue.rawValue)", category: "audio")
        }
    }

    private static func loadSound(named name: String, fileManager: FileManager) -> NSSound? {
        let systemURL = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        if fileManager.fileExists(atPath: systemURL.path) {
            return NSSound(contentsOf: systemURL, byReference: true)
        }

        return NSSound(named: NSSound.Name(name))
    }
}
