import Foundation
import HarnessKit

// Replays bus recordings (and optionally the Vera 1 corpus) through SceneBuilder under several
// configurations and prints a scoreboard. Prints numbers and ids only, never transcript text.

let usage = """
usage: swift run Harness [--recordings <file-or-dir> ...] [--corpus] [--labels <file-or-dir>]
                         [--configs name,name,...] [--out <markdown file>]

  --recordings  recording files, or directories of .jsonl recordings. Default: all recordings in
                ~/Library/Application Support/VeraSensorPrototype/Recordings (unless --corpus alone is given).
  --corpus      add the Vera 1 corpus episodes (Corpus/v1-episodes.jsonl), or use only them with no --recordings.
  --labels      a labels file (applied to every scenario) or a directory holding <scenario>.jsonl files.
                Default per recording: Recordings/Labels/<recording file name>.
  --configs     comma-separated configuration names. The baseline is always included. Default: all.
  --out         also write the scoreboard as Markdown (numbers only).
"""

struct Arguments {
    var recordings: [String] = []
    var recordingsGiven = false
    var corpus = false
    var labels: String?
    var configs: [String] = []
    var out: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func value(_ argv: [String], _ index: Int, _ flag: String) -> String {
    guard index < argv.count else { fail("missing value after \(flag)\n\(usage)") }
    return argv[index]
}

func parseArguments(_ argv: [String]) -> Arguments {
    var result = Arguments()
    var i = 0
    while i < argv.count {
        let flag = argv[i]
        switch flag {
        case "--recordings":
            result.recordingsGiven = true
            i += 1
            while i < argv.count, !argv[i].hasPrefix("--") {
                result.recordings.append(argv[i])
                i += 1
            }
            continue
        case "--corpus": result.corpus = true
        case "--labels":
            i += 1
            result.labels = value(argv, i, flag)
        case "--configs":
            i += 1
            result.configs = value(argv, i, flag).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--out":
            i += 1
            result.out = value(argv, i, flag)
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("unknown argument: \(flag)\n\(usage)")
        }
        i += 1
    }
    return result
}

func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

func jsonlFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Labels for one scenario: from `--labels`, otherwise `Labels/<recording file name>` beside the recording.
func labelsFile(scenario: String, recording: URL?, option: String?) -> URL? {
    if let option {
        let url = URL(filePath: option)
        guard isDirectory(url) else { return url }
        let file = url.appending(path: "\(scenario).jsonl")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    guard let recording else { return nil }
    let file = recording.deletingLastPathComponent().appending(path: "Labels/\(recording.lastPathComponent)")
    return FileManager.default.fileExists(atPath: file.path) ? file : nil
}

func runHarness(_ args: Arguments) throws -> String {
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/VeraSensorPrototype", directoryHint: .isDirectory)
    let recordingsDirectory = support.appending(path: "Recordings", directoryHint: .isDirectory)
    let corpusFile = support.appending(path: "Corpus/v1-episodes.jsonl")

    // Each scenario comes with the recording it was read from (nil for the corpus).
    var scenarios: [(scenario: Scenario, recording: URL?)] = []
    var recordingFiles: [URL] = []
    if args.recordingsGiven {
        guard !args.recordings.isEmpty else { fail("--recordings needs at least one path\n\(usage)") }
        for path in args.recordings {
            let url = URL(filePath: path)
            if isDirectory(url) { recordingFiles += try jsonlFiles(in: url) } else { recordingFiles.append(url) }
        }
    } else if !args.corpus {
        recordingFiles = try jsonlFiles(in: recordingsDirectory)
    }
    for url in recordingFiles {
        do {
            scenarios.append((try Scenario.load(recording: url), url))
        } catch {
            print("could not read \(url.lastPathComponent)")
        }
    }
    if args.corpus {
        guard FileManager.default.fileExists(atPath: corpusFile.path) else { fail("corpus not found") }
        scenarios += try Scenario.fromCorpus(url: corpusFile).map { ($0, nil) }
    }
    guard !scenarios.isEmpty else { throw HarnessError.noScenarios }

    let configurations = args.configs.isEmpty ? Configurations.all : try Configurations.named(args.configs)
    let baselineName = Configurations.baseline.name
    var combined: [String: [Metrics]] = [:]
    var combinedDifference: [String: (Int, Int)] = [:]
    var sections: [String] = []

    for (scenario, recording) in scenarios {
        var labels: [String: UtteranceLabel]?
        if let file = labelsFile(scenario: scenario.name, recording: recording, option: args.labels) {
            labels = try Labels.load(file)
        }
        let runs = configurations.map { ($0, Replayer.run(scenario, $0)) }
        guard let baseline = runs.first(where: { $0.0.name == baselineName })?.1 else { fail("baseline missing") }

        var rows: [ScoreRow] = []
        for (configuration, result) in runs {
            let metrics = Metrics(result, labels: labels)
            let difference = configuration.name == baselineName
                ? nil : ReadyDifference.between(baseline: baseline, configuration: result)
            rows.append(ScoreRow(name: configuration.name, metrics: metrics, difference: difference))
            combined[configuration.name, default: []].append(metrics)
            if let difference {
                let sum = combinedDifference[configuration.name] ?? (0, 0)
                combinedDifference[configuration.name] = (sum.0 + difference.onlyInConfiguration, sum.1 + difference.onlyInBaseline)
            }
        }
        let judge = runs.first?.1.judge.rawValue ?? "none"
        let utterances = baseline.endedUtterances.count
        let header = "## \(scenario.name)\n\nmessages \(scenario.messages.count), undecodable lines \(scenario.skippedLines), utterances \(utterances), turns \(baseline.decisions.count), baseline judge \(judge)\n"
        sections.append(header + "\n" + Scoreboard.markdown(title: "per scenario", rows: rows))
    }

    if scenarios.count > 1 {
        var rows: [ScoreRow] = []
        for configuration in configurations {
            let name = configuration.name
            let metrics = Metrics.combined(combined[name] ?? [])
            var difference: ReadyDifference?
            if name != baselineName, let sum = combinedDifference[name] {
                difference = ReadyDifference(onlyInConfiguration: sum.0, onlyInBaseline: sum.1)
            }
            rows.append(ScoreRow(name: name, metrics: metrics, difference: difference))
        }
        sections.append("## combined\n\n\(scenarios.count) scenarios\n\n" + Scoreboard.markdown(title: "combined", rows: rows))
    }
    return sections.joined(separator: "\n")
}

do {
    let args = parseArguments(Array(CommandLine.arguments.dropFirst()))
    let report = try runHarness(args)
    print(report)
    if let out = args.out {
        try report.write(to: URL(filePath: out), atomically: true, encoding: .utf8)
    }
} catch {
    fail("harness failed: \(error)")
}
