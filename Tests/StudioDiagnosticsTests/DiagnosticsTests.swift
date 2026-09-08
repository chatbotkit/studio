import Darwin
import Foundation
import Testing
import StudioDiagnostics

private final class TestBundleAnchor: NSObject {}

private func probeExecutable() -> URL {
    // SwiftPM builds executable targets alongside the xctest bundle. Do not use
    // argv[0], which is Xcode's testing helper rather than our test bundle.
    let directory = Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent()
    let executable = directory.appendingPathComponent("StudioCrashProbe")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    return executable
}

@Test func disconnectedClientCannotTerminateProtectedHost() throws {
    for mode in ["unprotected", "unprotected-relay", "protected"] {
        let process = Process()
        process.executableURL = probeExecutable()
        process.arguments = [mode]
        try process.run()
        process.waitUntilExit() // Child enforces a 10-second deadline.
        if mode == "protected" {
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == 0)
        } else {
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(process.terminationStatus == SIGPIPE)
        }
    }
}

@Test func lastDiagnosticSurvivesAnAbruptProcessExit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = probeExecutable()
    process.arguments = ["log-exit", directory.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
    let text = try String(contentsOf: directory.appendingPathComponent("current.jsonl"), encoding: .utf8)
    #expect(text.contains("last record before abrupt exit"))
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Test func logsSurviveReopeningAndHavePrivatePermissions() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try DiagnosticLog(directory: directory).append(source: "runtime", message: "before exit\nsecond line")
    try DiagnosticLog(directory: directory).append(source: "app", message: "next launch")
    let url = directory.appendingPathComponent("current.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let record = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
    #expect(record["message"] == "before exit\nsecond line")
    #expect(record["pid"] == String(getpid()))
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
}

@Test func logsStayBoundedAndRetainTheNewestRecords() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try DiagnosticLog(directory: directory, maxBytes: 1024, archives: 3)
    for index in 0..<100 { log.append(source: "service", message: "\(index) " + String(repeating: "👋", count: 50_000)) }
    log.append(source: "app", message: "newest")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
    #expect(files.count == 4)
    for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 1024)
        for line in data.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
    }
    #expect(try String(contentsOf: directory.appendingPathComponent("current.jsonl"), encoding: .utf8).contains("newest"))
}

@Test func logsCanRotateWithoutArchives() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try DiagnosticLog(directory: directory, maxBytes: 1024, archives: 0)
    for _ in 0..<10 { log.append(source: "runtime", message: String(repeating: "x", count: 600)) }
    #expect(try Data(contentsOf: directory.appendingPathComponent("current.jsonl")).count <= 1024)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("previous-1.jsonl").path))
}

@Test func loggingRefusesSymlinksAndFailsWithoutBreakingTheCaller() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("protected.txt")
    try Data("unchanged".utf8).write(to: target)
    let current = directory.appendingPathComponent("current.jsonl")
    try FileManager.default.createSymbolicLink(at: current, withDestinationURL: target)
    let log = try DiagnosticLog(directory: directory)
    log.append(source: "app", message: "must not overwrite")
    log.append(source: "app", message: "still safe after failure")
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
}

@Test func concurrentLogWritesRemainComplete() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try DiagnosticLog(directory: directory)
    DispatchQueue.concurrentPerform(iterations: 100) { log.append(source: "test", message: "message \($0)") }
    let lines = try Data(contentsOf: directory.appendingPathComponent("current.jsonl")).split(separator: 10)
    #expect(lines.count == 100)
    for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line)) }
}
