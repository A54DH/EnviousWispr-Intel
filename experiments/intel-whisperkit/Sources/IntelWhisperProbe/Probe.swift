import AVFoundation
import CoreML
import Darwin
import Foundation
import Metal
import WhisperKit

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Inference: Codable {
    let iteration: Int
    let kind: String
    let seconds: Double
    let realTimeFactor: Double
    let transcript: String
}

private struct Report: Codable {
    var schemaVersion = 1
    var status = "running"
    var stage = "arguments"
    var requestedCompute = ""
    var requestedModel = ""
    var resolvedModelFolder: String?
    var modelRepo = "argmaxinc/whisperkit-coreml"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var processorCount = ProcessInfo.processInfo.processorCount
    var physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    var availableMetalDevices: [String] = []
    var audioSeconds: Double?
    var downloadSeconds: Double?
    var loadSeconds: Double?
    var inferences: [Inference] = []
    var error: String?

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

@main
private enum IntelWhisperProbe {
    static func main() async {
        // Deliberately small positional interface; run.py validates all inputs.
        // AUDIO_PATH CACHE_DIRECTORY COMPUTE MODEL REPORT_PATH
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else {
            fputs("Usage: intel-whisper-probe AUDIO CACHE cpu|cpu-gpu MODEL REPORT\n", stderr)
            exit(2)
        }
        let audioURL = URL(fileURLWithPath: args[0])
        let cacheURL = URL(fileURLWithPath: args[1])
        let reportURL = URL(fileURLWithPath: args[4])
        var report = Report()
        report.requestedCompute = args[2]
        report.requestedModel = args[3]

        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.save(to: reportURL)
            #if !arch(x86_64)
            throw ProbeFailure(message: "This probe requires an Intel x86_64 build.")
            #endif

            let units: MLComputeUnits
            switch args[2] {
            case "cpu": units = .cpuOnly
            case "cpu-gpu": units = .cpuAndGPU
            default: throw ProbeFailure(message: "Compute must be cpu or cpu-gpu.")
            }
            report.availableMetalDevices = MTLCopyAllDevices().map { $0.name }
            let audioFile = try AVAudioFile(forReading: audioURL)
            let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0 else {
                throw ProbeFailure(message: "The audio fixture is empty or has an invalid duration.")
            }
            report.audioSeconds = seconds

            report.stage = "model_download"
            try report.save(to: reportURL)
            let downloadStart = ProcessInfo.processInfo.systemUptime
            let modelFolder = try await WhisperKit.download(
                variant: args[3], downloadBase: cacheURL, from: report.modelRepo)
            report.downloadSeconds = ProcessInfo.processInfo.systemUptime - downloadStart
            report.resolvedModelFolder = modelFolder.path
            guard modelFolder.lastPathComponent == args[3] else {
                throw ProbeFailure(message: "Unexpected model selected: \(modelFolder.lastPathComponent)")
            }

            report.stage = "model_load"
            try report.save(to: reportURL)
            let loadStart = ProcessInfo.processInfo.systemUptime
            let config = WhisperKitConfig(
                model: args[3],
                downloadBase: cacheURL,
                modelFolder: modelFolder.path,
                tokenizerFolder: cacheURL,
                computeOptions: ModelComputeOptions(
                    melCompute: units, audioEncoderCompute: units, textDecoderCompute: units),
                verbose: true,
                logLevel: .info,
                prewarm: false,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            report.loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            let options = DecodingOptions(
                language: "en", temperature: 0, temperatureFallbackCount: 0,
                usePrefillPrompt: true, detectLanguage: false,
                skipSpecialTokens: true, withoutTimestamps: true
            )

            for iteration in 1...3 {
                report.stage = "transcription_\(iteration)"
                try report.save(to: reportURL)
                let start = ProcessInfo.processInfo.systemUptime
                let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let transcript = results.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                report.inferences.append(Inference(
                    iteration: iteration,
                    kind: iteration == 1 ? "first_in_process" : "warmed_repeat",
                    seconds: elapsed,
                    realTimeFactor: elapsed / seconds,
                    transcript: transcript
                ))
                try report.save(to: reportURL)
                guard !transcript.isEmpty else {
                    throw ProbeFailure(message: "Transcription returned no text.")
                }
            }
            // Correctness is scored independently by run.py, not by a successful exit.
            report.stage = "complete"
            report.status = "completed"
            try report.save(to: reportURL)
        } catch {
            report.status = "failed"
            report.error = String(reflecting: error)
            do { try report.save(to: reportURL) }
            catch { fputs("Could not save diagnostic report: \(error)\n", stderr) }
            fputs("Intel WhisperKit probe failed during \(report.stage): \(error)\n", stderr)
            exit(1)
        }
    }
}
