import Foundation

public struct ModelRuntime: Sendable {
    public let vera1Root: URL
    public let pythonURL: URL
    public let gigaAMModelURL: URL
    public let speakerModelURL: URL
    public let voxLockModelDirectory: URL
    public let jevPythonURL: URL
    public let smartTurnModelURL: URL
    public let sileroVADModelURL: URL
    public let nomoPythonURL: URL
    public let nomoModelDirectory: URL
    public let appSupportURL: URL
    public let usersURL: URL
    public let peopleDatabaseURL: URL
    public let alexTargetVoiceURL: URL

    public init(vera1Root: URL? = nil) {
        let root = vera1Root ?? Self.discoverVera1Root()
        self.vera1Root = root
        self.pythonURL = root.appending(path: "Support/silero-tts/.venv/bin/python")
        self.gigaAMModelURL = root.appending(path: "Support/gigaam-asr/models/gigaam-v3-e2e-ctc")
        self.speakerModelURL = root.appending(path: "Support/silero-tts/models/sherpa/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")
        self.voxLockModelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Vera/Models/VoxLock", directoryHint: .isDirectory)
        self.appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VeraSensorPrototype", directoryHint: .isDirectory)
        self.usersURL = appSupportURL.appending(path: "Users", directoryHint: .isDirectory)
        self.peopleDatabaseURL = usersURL.appending(path: "people.sqlite")
        self.alexTargetVoiceURL = usersURL.appending(path: "voice-samples/alex/enrollment/target-voice-5.wav")
        self.sileroVADModelURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VeraSensorPrototype/Models/SileroVAD/silero_vad.onnx")
        self.smartTurnModelURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VeraSensorPrototype/Models/SmartTurn/smart-turn-v3.2-cpu.onnx")
        self.jevPythonURL = root.appending(path: "Support/jev-decision/.venv/bin/python")
        self.nomoPythonURL = appSupportURL.appending(path: "Python/NomoPVAD/bin/python")
        self.nomoModelDirectory = appSupportURL.appending(path: "Models/NomoPVAD", directoryHint: .isDirectory)
    }

    public var gigaAMAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
        FileManager.default.fileExists(atPath: gigaAMModelURL.appending(path: "v3_e2e_ctc.onnx").path)
    }

    public var speakerModelAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
        FileManager.default.fileExists(atPath: speakerModelURL.path)
    }

    public var voxLockAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
        FileManager.default.fileExists(atPath: voxLockModelDirectory.appending(path: "voxlock_enroll.onnx").path) &&
        FileManager.default.fileExists(atPath: voxLockModelDirectory.appending(path: "voxlock_chunk_int8.onnx").path)
    }

    /// Jev-Style 2B (MLX, 8 bit) runs from Vera 1's separate environment; weights come from the Hugging Face cache.
    public var jevAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: jevPythonURL.path) &&
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/huggingface/hub/models--chaoliangUNSW--Jev-Style-2B-Decision-v4-MLX").path)
    }

    /// Smart Turn v3.2 (Pipecat, BSD-2): end-of-turn from audio. Runs in the shared Silero/GigaAM environment
    /// (onnxruntime, soundfile, scipy); the 8.7 MB model was downloaded from the official Hugging Face repository.
    public var smartTurnAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
        FileManager.default.fileExists(atPath: smartTurnModelURL.path)
    }

    /// Silero VAD v5 (MIT, 2.3 MB ONNX): speech probability per 32 ms window. Runs next to the energy gate, in the
    /// shared Silero/GigaAM environment.
    public var sileroVADAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) &&
        FileManager.default.fileExists(atPath: sileroVADModelURL.path)
    }

    public var nomoPVADAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: nomoPythonURL.path) &&
        FileManager.default.fileExists(atPath: nomoModelDirectory.appending(path: "nomo_pvad.pt").path) &&
        FileManager.default.fileExists(atPath: nomoModelDirectory.appending(path: "pretrained_eres2netv2.ckpt").path)
    }

    public func createRuntimeDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: appSupportURL.appending(path: "Logs", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: usersURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: usersURL.path)
    }

    private static func discoverVera1Root() -> URL {
        if let configured = ProcessInfo.processInfo.environment["VERA_V1_ROOT"],
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: configured).appending(path: "Support").path) {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "vera", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: fromSource.appending(path: "Support").path) { return fromSource }
        return URL(fileURLWithPath: "/Users/alex/Projects/vera", isDirectory: true)
    }
}
