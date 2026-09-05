import Foundation
import Testing
@testable import Studio

private final class CapturedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ lines: [String]) { lock.withLock { storage.append(contentsOf: lines) } }
    var lines: [String] { lock.withLock { storage } }
}

@Test func logChunksPreserveLinesAndFlushTailOnce() throws {
    let captured = CapturedLines()
    let writer = MemoryWriter { captured.append($0) }
    try writer.write(Data("fir".utf8))
    #expect(captured.lines.isEmpty)
    try writer.write(Data("st\r\n\nsecond\nlast".utf8))
    #expect(captured.lines == ["first", "second"])
    try writer.close()
    try writer.close()
    #expect(captured.lines == ["first", "second", "last"])
    #expect(writer.text() == "first\r\n\nsecond\nlast")
}

@Test func logStorageKeepsOnlyItsBoundedTail() throws {
    let writer = MemoryWriter()
    try writer.write(Data(repeating: 65, count: 1_000_000))
    try writer.write(Data("latest\n".utf8))
    #expect(writer.text().utf8.count == 1_000_000)
    #expect(writer.text().hasSuffix("latest\n"))
}

@Test func unterminatedLogsAreDeliveredBeforeClose() throws {
    let captured = CapturedLines()
    let writer = MemoryWriter { captured.append($0) }
    let line = String(repeating: "a", count: 16_385)
    try writer.write(Data(line.utf8))
    #expect(captured.lines == [String(line.prefix(16_384))])
    try writer.close()
    #expect(captured.lines.joined() == line)
}

@Test func logUnicodeSurvivesEveryByteBoundary() throws {
    let source = "café — 日本語 👩🏽‍💻\n"
    let data = Data(source.utf8)
    var brokenBoundaries: [Int] = []
    for boundary in 1..<data.count {
        let captured = CapturedLines()
        let writer = MemoryWriter { captured.append($0) }
        try writer.write(Data(data.prefix(boundary)))
        try writer.write(Data(data.dropFirst(boundary)))
        try writer.close()
        if captured.lines != [String(source.dropLast())] { brokenBoundaries.append(boundary) }
        #expect(writer.text() == source)
    }
    #expect(brokenBoundaries.isEmpty)
}

@Test func invalidLogBytesDoNotHideSubsequentText() throws {
    let captured = CapturedLines()
    let writer = MemoryWriter { captured.append($0) }
    try writer.write(Data([0xff]) + Data("useful error\n".utf8))
    try writer.close()
    #expect(captured.lines.joined().contains("useful error"))
    #expect(writer.text().contains("useful error"))
}

@Test func boundedLogTailRemainsReadableAfterSplittingUnicode() throws {
    let writer = MemoryWriter()
    try writer.write(Data("é".utf8) + Data(repeating: 65, count: 999_999))
    #expect(writer.text().hasSuffix(String(repeating: "A", count: 100)))
}

@Test func unterminatedUnicodeLinesRemainBoundedAndLossless() throws {
    let captured = CapturedLines()
    let writer = MemoryWriter { captured.append($0) }
    let source = String(repeating: "a", count: 16_383) + String(repeating: "👋", count: 10_000)
    for byte in source.utf8 { try writer.write(Data([byte])) }
    try writer.close()
    #expect(captured.lines.joined() == source)
    #expect(captured.lines.allSatisfy { $0.utf8.count <= 16_384 })
}

@Test func logCloseRejectsFurtherWrites() throws {
    let writer = MemoryWriter()
    try writer.close()
    #expect(throws: AppRuntimeError.self) { try writer.write(Data("late".utf8)) }
}

@Test func listenerGateHandlesCompletionBeforeInstallation() async throws {
    let gate = ListenerGate()
    gate.finish(.success(()))
    gate.finish(.failure(AppRuntimeError("must not replace success")))
    try await withCheckedThrowingContinuation { gate.install($0) }
}

@Test func listenerGatePreservesFirstFailure() async {
    let gate = ListenerGate()
    gate.finish(.failure(AppRuntimeError("first failure")))
    gate.finish(.success(()))
    do {
        try await withCheckedThrowingContinuation { gate.install($0) }
        Issue.record("Expected the original failure")
    } catch {
        #expect(error.localizedDescription == "first failure")
    }
}

@Test func listenerGateResumesInstalledContinuationOnlyOnce() async throws {
    let gate = ListenerGate()
    try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        gate.finish(.success(()))
        gate.finish(.success(()))
    }
}

@Test func listenerGateSerializesConcurrentCompletions() async throws {
    let gate = ListenerGate()
    try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in gate.finish(.success(())) }
    }
}

@Test func busyPhasesBlockRestart() {
    for phase: StackPhase in [.resolving, .pulling, .creating, .starting, .stopping] {
        #expect(phase.busy)
    }
    #expect(!StackPhase.idle.busy)
    #expect(!StackPhase.failed("fixture").busy)
}
