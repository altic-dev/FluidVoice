# Voxtral MLX Integration Plan

**Status:** 🚧 In Progress
**Assigned:** Schurl
**Created:** 2026-02-05

## Ziel

Voxtral MLX als neues Speech-to-Text Modell in FluidVoice integrieren.

## Dependency hinzufügen

In `Package.swift`:
```swift
.package(url: "https://github.com/VincentGourbin/mlx-voxtral-swift", branch: "main")

// In target dependencies:
.product(name: "VoxtralCore", package: "mlx-voxtral-swift")
```

## Neue Dateien

### 1. `Sources/Fluid/Services/VoxtralMLXProvider.swift`

```swift
import Foundation
import VoxtralCore

/// TranscriptionProvider implementation using Voxtral MLX for Apple Silicon
final class VoxtralMLXProvider: TranscriptionProvider {
    let name = "Voxtral MLX"
    
    var isAvailable: Bool {
        CPUArchitecture.isAppleSilicon
    }
    
    private var pipeline: VoxtralPipeline?
    private(set) var isReady: Bool = false
    private var loadedModel: SettingsStore.SpeechModel?
    
    var modelOverride: SettingsStore.SpeechModel?
    
    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride
    }
    
    private var currentModel: SettingsStore.SpeechModel {
        modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }
    
    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        guard isReady == false else { return }
        
        let model = currentModel
        let voxtralModel: VoxtralPipeline.Model = switch model {
            case .voxtralMini: .mini3b
            case .voxtralMini8bit: .mini3b8bit
            case .voxtralMini4bit: .mini3b4bit
            default: .mini3b8bit // Default to 8-bit for best speed/quality
        }
        
        pipeline = VoxtralPipeline(model: voxtralModel, backend: .auto)
        
        try await pipeline?.loadModel { progress, status in
            progressHandler?(progress)
        }
        
        loadedModel = model
        isReady = true
    }
    
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let pipeline = pipeline else {
            throw NSError(domain: "VoxtralMLXProvider", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Voxtral model not loaded"])
        }
        
        // Convert samples to audio URL (Voxtral expects file input)
        let tempURL = try createTempAudioFile(from: samples)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let text = try await pipeline.transcribe(audio: tempURL, language: "auto")
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }
    
    func modelsExistOnDisk() -> Bool {
        // Check if model weights are cached
        // VoxtralCore handles caching via HuggingFace Hub
        return true // Simplified - VoxtralCore auto-downloads
    }
    
    func clearCache() async throws {
        pipeline?.unload()
        pipeline = nil
        isReady = false
        loadedModel = nil
    }
    
    private func createTempAudioFile(from samples: [Float]) throws -> URL {
        // Convert Float samples to WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("voxtral_input_\(UUID().uuidString).wav")
        
        // Write WAV header + PCM data (16kHz mono)
        var data = Data()
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(samples.count * 2)
        
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: (36 + dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (numChannels * bitsPerSample / 8).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        
        // Convert Float [-1, 1] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }
        
        try data.write(to: tempURL)
        return tempURL
    }
}
```

## Bestehende Dateien ändern

### 2. `Sources/Fluid/Persistence/SettingsStore.swift`

Im `SpeechModel` enum hinzufügen:

```swift
// MARK: - Voxtral MLX Models (Apple Silicon Only)
case voxtralMini = "voxtral-mini"
case voxtralMini8bit = "voxtral-mini-8bit"  
case voxtralMini4bit = "voxtral-mini-4bit"
```

Properties erweitern:

```swift
var displayName: String {
    // ... existing cases ...
    case .voxtralMini: return "Voxtral Mini 3B"
    case .voxtralMini8bit: return "Voxtral Mini 3B (8-bit)"
    case .voxtralMini4bit: return "Voxtral Mini 3B (4-bit)"
}

var languageSupport: String {
    case .voxtralMini, .voxtralMini8bit, .voxtralMini4bit: return "13 Languages"
}

var downloadSize: String {
    case .voxtralMini: return "~6 GB"
    case .voxtralMini8bit: return "~3.5 GB"
    case .voxtralMini4bit: return "~2 GB"
}

var requiresAppleSilicon: Bool {
    case .voxtralMini, .voxtralMini8bit, .voxtralMini4bit: return true
}

var isVoxtralModel: Bool {
    switch self {
    case .voxtralMini, .voxtralMini8bit, .voxtralMini4bit: return true
    default: return false
    }
}
```

### 3. `Sources/Fluid/Services/ASRService.swift`

Provider-Cache hinzufügen:

```swift
private var voxtralMLXProvider: VoxtralMLXProvider?
```

Getter hinzufügen:

```swift
private func getVoxtralMLXProvider() -> VoxtralMLXProvider {
    if let existing = voxtralMLXProvider {
        return existing
    }
    let provider = VoxtralMLXProvider()
    self.voxtralMLXProvider = provider
    DebugLogger.shared.info("ASRService: Created VoxtralMLX provider", source: "ASRService")
    return provider
}
```

In `transcriptionProvider` getter erweitern:

```swift
private var transcriptionProvider: TranscriptionProvider {
    let model = SettingsStore.shared.selectedSpeechModel
    
    switch model {
    // ... existing cases ...
    case .voxtralMini, .voxtralMini8bit, .voxtralMini4bit:
        return self.getVoxtralMLXProvider()
    default:
        return self.getWhisperProvider()
    }
}
```

In `getProvider(for:)` erweitern:

```swift
func getProvider(for model: SettingsStore.SpeechModel) -> TranscriptionProvider {
    switch model {
    // ... existing cases ...
    case .voxtralMini, .voxtralMini8bit, .voxtralMini4bit:
        return VoxtralMLXProvider(modelOverride: model)
    default:
        return WhisperProvider(modelOverride: model)
    }
}
```

In `resetTranscriptionProvider()`:

```swift
self.voxtralMLXProvider = nil
```

### 4. `Package.swift`

```swift
dependencies: [
    // ... existing ...
    .package(url: "https://github.com/VincentGourbin/mlx-voxtral-swift", branch: "main"),
],
targets: [
    .executableTarget(
        name: "FluidVoice",
        dependencies: [
            // ... existing ...
            .product(name: "VoxtralCore", package: "mlx-voxtral-swift"),
        ]
    ),
]
```

## Testing

1. Build in Xcode
2. Select Voxtral Mini 4-bit in settings
3. Download model (first time)
4. Test transcription
5. Verify German language works

## Notes

- VoxtralCore erwartet Audio-Files, nicht raw samples → Temp WAV erstellen
- Model-Download via HuggingFace Hub (automatisch)
- 4-bit empfohlen für beste Performance (~17 tok/s)
