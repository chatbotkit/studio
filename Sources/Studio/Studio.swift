import AppKit
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationIO
import ContainerizationOCI
import ContainerizationOS
import CryptoKit
import Foundation
import Network
import SwiftUI
import StudioConfiguration
import SystemPackage
import WebKit

let defaultOCIReference = "oci://ghcr.io/chatbotkit/platform-studio:latest"
private let serviceNames = ["db-init", "redis", "qdrant", "garage", "garage-init", "platform"]

struct AppRuntimeError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MemoryWriter: Writer, @unchecked Sendable {
    // Serialize delivery as well as storage. Recursive so a callback may read
    // text() without deadlocking; callbacks enqueue UI work and stay short.
    private let lock = NSRecursiveLock()
    private var storage = Data()
    private var pendingLine = Data()
    private var closed = false
    private let onLines: (@Sendable ([String]) -> Void)?

    init(onLines: (@Sendable ([String]) -> Void)? = nil) {
        self.onLines = onLines
    }

    func write(_ data: Data) throws {
        var completed: [String] = []
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw AppRuntimeError("Cannot write to a closed log stream.") }
        storage.append(data)
        if storage.count > 1_000_000 { storage.removeFirst(storage.count - 1_000_000) }
        for byte in data {
            if byte == 10 {
                completed.append(String(decoding: pendingLine, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                pendingLine.removeAll(keepingCapacity: true)
            } else {
                pendingLine.append(byte)
                if pendingLine.count > 16_384 {
                    // Bound unterminated lines without splitting a valid UTF-8
                    // scalar. Invalid bytes use replacement characters.
                    var length = 16_384
                    while length > 16_381, pendingLine[pendingLine.startIndex + length] & 0xc0 == 0x80 { length -= 1 }
                    completed.append(String(decoding: pendingLine.prefix(length), as: UTF8.self))
                    pendingLine = Data(pendingLine.dropFirst(length))
                }
            }
        }
        let visible = completed.filter { !$0.isEmpty }
        if !visible.isEmpty { onLines?(visible) }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let tail = String(decoding: pendingLine, as: UTF8.self)
        pendingLine.removeAll()
        if !tail.isEmpty { onLines?([tail]) }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}

private final class OneShotDataReader: ReaderStream, @unchecked Sendable {
    private let data: Data

    init(_ data: Data) {
        self.data = data
    }

    func stream() -> AsyncStream<Data> {
        let data = self.data
        return AsyncStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }
    }
}

// MARK: - OCI Compose artifact

struct OCIStackBundle: Sendable {
    let sourceReference: String
    let resolvedDigest: String
    let composeYAML: String
    let digestLockYAML: String
    let images: [String: String]
    let garageConfiguration: String
}

enum OCIComposeLoader {
    static func load(reference source: String, cacheRoot: URL) async throws -> OCIStackBundle {
        guard source.hasPrefix("oci://") else {
            throw AppRuntimeError("The stack source must begin with oci://")
        }
        let rawReference = String(source.dropFirst("oci://".count))
        let reference = try Reference.parse(rawReference)
        guard reference.domain != nil, !reference.path.isEmpty else {
            throw AppRuntimeError("Use a fully-qualified OCI registry reference.")
        }
        guard reference.digest == nil else {
            throw AppRuntimeError("This prototype expects an OCI tag, not a manifest digest.")
        }

        let client = try RegistryClient(reference: rawReference)
        let repository = reference.path
        let root = try await client.resolve(name: repository, tag: reference.tag ?? "latest")
        let (composeData, lockData) = try await VerifiedComposeArtifact.load(root: root) {
            try await client.fetchData(name: repository, descriptor: $0)
        }
        guard let compose = String(data: composeData, encoding: .utf8),
              let lock = String(data: lockData, encoding: .utf8) else {
            throw AppRuntimeError("The OCI YAML layers are not valid UTF-8.")
        }

        let images = try parseImageLock(lock)
        for name in serviceNames where images[name] == nil {
            throw AppRuntimeError("The OCI digest lock is missing service \(name).")
        }
        for name in serviceNames where !compose.contains("  \(name):") {
            throw AppRuntimeError("The OCI Compose file is missing service \(name).")
        }
        let garage = try GarageConfiguration.extract(from: compose)

        let artifactRoot = cacheRoot.appendingPathComponent(root.digest.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        try composeData.write(to: artifactRoot.appendingPathComponent("compose.yml"), options: .atomic)
        try lockData.write(to: artifactRoot.appendingPathComponent("image-digests.yml"), options: .atomic)

        return OCIStackBundle(
            sourceReference: source,
            resolvedDigest: root.digest,
            composeYAML: compose,
            digestLockYAML: lock,
            images: images,
            garageConfiguration: garage
        )
    }

    static func verify(_ data: Data, descriptor: Descriptor) throws {
        guard data.count == Int(descriptor.size) else {
            throw AppRuntimeError("An OCI layer had an unexpected size.")
        }
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.digest else {
            throw AppRuntimeError("An OCI layer failed SHA-256 verification.")
        }
    }

    static func parseImageLock(_ yaml: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var inServices = false
        var sawServices = false
        var names: Set<String> = []
        for raw in yaml.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent == 0 {
                inServices = trimmed == "services:"
                current = nil
                if inServices {
                    guard !sawServices else { throw AppRuntimeError("The image lock contains duplicate services sections.") }
                    sawServices = true
                }
                continue
            }
            guard inServices else { continue }
            if indent == 2, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                current = String(trimmed.dropLast())
                guard names.insert(current!).inserted else { throw AppRuntimeError("The image lock contains duplicate service \(current!).") }
            } else if indent == 4, trimmed.hasPrefix("image:"), let current {
                var image = trimmed.dropFirst("image:".count).trimmingCharacters(in: .whitespaces)
                if let first = image.first, ["\"", "'"].contains(first), image.last == first, image.count >= 2 {
                    image = String(image.dropFirst().dropLast())
                }
                guard result[current] == nil else { throw AppRuntimeError("The image lock contains duplicate image keys for \(current).") }
                guard image.range(of: "^[^\\s@]+@sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw AppRuntimeError("Image \(current) must be pinned to a valid SHA-256 digest.")
                }
                _ = try Reference.parse(image)
                result[current] = image
            } else if indent <= 2 {
                throw AppRuntimeError("Unsupported service entry in the image lock.")
            }
        }
        return result
    }

}

// MARK: - Localhost TCP publication

final class ListenerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class TCPRelay: @unchecked Sendable {
    private let incoming: NWConnection
    private let outgoing: NWConnection
    private let queue: DispatchQueue
    private let finish: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    init(incoming: NWConnection, unixSocketPath: String, queue: DispatchQueue, finish: @escaping @Sendable () -> Void) {
        self.incoming = incoming
        self.outgoing = NWConnection(to: .unix(path: unixSocketPath), using: .tcp)
        self.queue = queue
        self.finish = finish
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.close() } }
        outgoing.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.incoming, to: self.outgoing)
                self.pump(from: self.outgoing, to: self.incoming)
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError == nil, !complete, error == nil {
                        self.pump(from: source, to: destination)
                    } else {
                        self.close()
                    }
                })
            } else if complete || error != nil {
                self.close()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        incoming.cancel()
        outgoing.cancel()
        finish()
    }
}

private final class LocalTCPForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.cbk.private-oci-stack.forwarder", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var relays: [UUID: TCPRelay] = [:]

    func start(preferredPort: UInt16, targetUnixSocketPath: String, allowFallback: Bool = true, excluding: Set<UInt16> = []) async throws -> UInt16 {
        stop()
        var lastError: Error?
        let lastPort = UInt16(min(Int(preferredPort) + (allowFallback ? 9 : 0), Int(UInt16.max)))
        for port in preferredPort...lastPort {
            if excluding.contains(port) { continue }
            try Task.checkCancellation()
            do {
                try await startOne(port: port, targetUnixSocketPath: targetUnixSocketPath)
                return port
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw AppRuntimeError("Could not publish localhost ports \(preferredPort)–\(lastPort): \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func startOne(port: UInt16, targetUnixSocketPath: String) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw AppRuntimeError("Invalid port \(port).") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort)
        let candidate = try NWListener(using: parameters)
        let gate = ListenerGate()
        candidate.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, unixSocketPath: targetUnixSocketPath)
        }
        candidate.stateUpdateHandler = { state in
            switch state {
            case .ready: gate.finish(.success(()))
            case let .failed(error): gate.finish(.failure(error))
            case .cancelled: gate.finish(.failure(AppRuntimeError("The localhost listener was cancelled.")))
            default: break
            }
        }
        candidate.start(queue: queue)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { gate.install($0) }
                try Task.checkCancellation()
            } onCancel: {
                candidate.cancel()
                gate.finish(.failure(CancellationError()))
            }
            lock.withLock { listener = candidate }
        } catch {
            candidate.cancel()
            throw error
        }
    }

    private func accept(_ connection: NWConnection, unixSocketPath: String) {
        let id = UUID()
        let relay = TCPRelay(incoming: connection, unixSocketPath: unixSocketPath, queue: queue) { [weak self] in
            self?.lock.lock()
            self?.relays[id] = nil
            self?.lock.unlock()
        }
        lock.lock()
        relays[id] = relay
        lock.unlock()
        relay.start()
    }

    func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        let activeRelays = Array(relays.values)
        relays.removeAll()
        lock.unlock()
        activeListener?.cancel()
        activeRelays.forEach { $0.close() }
    }
}

// MARK: - Stack runtime

enum ServicePhase: Equatable {
    case pending, preparing, waiting, starting, healthy, complete, stopped, failed

    var title: String {
        switch self {
        case .pending: "Pending"
        case .preparing: "Preparing image"
        case .waiting: "Waiting"
        case .starting: "Starting"
        case .healthy: "Healthy"
        case .complete: "Complete"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .healthy, .complete: .green
        case .starting, .preparing: .primary
        case .waiting: .yellow
        case .failed: .red
        default: .secondary
        }
    }
}

enum StackPhase: Equatable {
    case idle, resolving, pulling, creating, starting, ready(StackInfo), stopping, failed(String)

    var title: String {
        switch self {
        case .idle: "Ready"
        case .resolving: "Resolving OCI Compose artifact"
        case .pulling: "Preparing digest-locked images"
        case .creating: "Creating private Linux pod"
        case .starting: "Starting the stack"
        case .ready: "Stack is healthy"
        case .stopping: "Stopping stack"
        case .failed: "Stack failed"
        }
    }

    var busy: Bool {
        switch self {
        case .resolving, .pulling, .creating, .starting, .stopping: true
        default: false
        }
    }
}

struct StackInfo: Sendable, Equatable {
    let url: URL
    let podID: String
    let dataRoot: String
    let sourceReference: String
    let resolvedDigest: String
    let composeYAML: String
    let publishedPort: UInt16
}

enum RuntimeEvent: Sendable {
    case phase(StackPhase)
    case service(String, ServicePhase)
    case progress(Double, String)
    case log(String)
    case containerLines(String, [String])
}

struct ContainerLogEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let service: String
    let message: String

    init(service: String, message: String) {
        self.id = UUID()
        self.timestamp = .now
        self.service = service
        self.message = message
    }
}

private struct ServicePlan: Sendable {
    let name: String
    let image: String
    let environment: ComposeEnvironment
    let command: [String]?
    let mounts: [(name: String, destination: String)]
    let fileMount: (source: String, destination: String)?
}

actor PrivateOCIStackRuntime: StackRuntime {
    private static let initImage = "ghcr.io/apple/containerization/vminit:0.43.0"
    private static let bootstrapAddress = "192.0.2.2"
    private var pod: LinuxPod?
    private var forwarder: LocalTCPForwarder?
    private var auxiliaryForwarders: [LocalTCPForwarder] = []
    private var bridgeProcess: LinuxProcess?
    private var outputs: [String: MemoryWriter] = [:]
    private var startedServices: Set<String> = []
    private var starting = false
    private var storageLease: RuntimeStorageLease?

    func start(kernelURL: URL, dataRoot: URL, event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void) async throws -> StackInfo {
        guard !starting else { throw AppRuntimeError("The private stack is already starting.") }
        starting = true
        defer { starting = false }
        _ = try await stop()
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            storageLease = try RuntimeStorageLease(root: dataRoot)
            return try await prepareAndStart(kernelURL: kernelURL, dataRoot: dataRoot, event: event)
        } catch {
            let startupError = error
            // Cleanup must not inherit the cancelled startup task. Cover every
            // resource acquisition, including failures before pod creation.
            do {
                let warnings = try await Task { try await self.stop() }.value
                if !warnings.isEmpty { await event(.containerLines("runtime", warnings)) }
            }
            catch { throw AppRuntimeError("\(startupError.localizedDescription)\n\(error.localizedDescription)") }
            throw startupError
        }
    }

    private func prepareAndStart(kernelURL: URL, dataRoot: URL, event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void) async throws -> StackInfo {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try DiskSafety.require(at: dataRoot, additional: 0)

        await event(.phase(.resolving))
        await event(.progress(0.03, "Resolving OCI Compose artifact"))
        let bundle = try await OCIComposeLoader.load(
            reference: defaultOCIReference,
            cacheRoot: dataRoot.appendingPathComponent("artifacts", isDirectory: true)
        )
        try Task.checkCancellation()
        await event(.log("Verified OCI manifest \(short(bundle.resolvedDigest))"))
        await event(.log("Loaded compose.yml and digest-locked image map"))

        // Unix-domain socket paths are limited to roughly 100 bytes on macOS.
        // The Application Support runtime path is intentionally descriptive but
        // too long, while the app's sandboxed temporary directory is short.
        let hostSocket = FileManager.default.temporaryDirectory.appendingPathComponent("private-oci-http.sock")
        try? FileManager.default.removeItem(at: hostSocket)
        let localForwarder = LocalTCPForwarder()
        let hostPort = try await localForwarder.start(preferredPort: 3000, targetUnixSocketPath: hostSocket.path, excluding: [3001])
        forwarder = localForwarder
        if hostPort == 3000 {
            await event(.log("Reserved http://localhost:3000"))
        } else {
            await event(.log("Port 3000 is occupied; safely using localhost:\(hostPort)"))
        }

        let garageFile = dataRoot.appendingPathComponent("garage.toml")
        try Data(bundle.garageConfiguration.utf8).write(to: garageFile, options: .atomic)
        let plans = try makePlans(bundle: bundle, hostPort: hostPort, garageFile: garageFile)
        let platformEnvironment = plans.first { $0.name == "platform" }!.environment.values
        var bridgePorts: [UInt16] = [3000]
        if platformEnvironment["RELAY_URL"] != nil { bridgePorts.append(3001) }
        if platformEnvironment["STORAGE_ENDPOINT"] != nil { bridgePorts.append(3900) }
        for port in bridgePorts.dropFirst() {
            let auxiliary = LocalTCPForwarder()
            _ = try await auxiliary.start(preferredPort: port, targetUnixSocketPath: hostSocket.path + ".\(port)", allowFallback: false)
            auxiliaryForwarders.append(auxiliary)
            await event(.log("Reserved loopback service port \(port)"))
        }
        await event(.log("Applied Compose environment for all services (trusted local sign-in: \(platformEnvironment["NEXTAUTH_TRUSTED_SIGNIN"] == "true" ? "enabled" : "not enabled"))"))
        for plan in plans { await event(.service(plan.name, .preparing)) }

        await event(.phase(.pulling))
        let store = try ImageStore(path: dataRoot.appendingPathComponent("images", isDirectory: true))
        await event(.progress(0.08, "Preparing the private VM runtime"))
        let initfs = try await prepareInitfs(store: store, at: dataRoot.appendingPathComponent("initfs.ext4"))

        let serviceRoot = dataRoot.appendingPathComponent("services", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
        var rootfs: [String: Containerization.Mount] = [:]
        var processConfigs: [String: LinuxProcessConfiguration] = [:]
        var protectedImages: Set<String> = [Self.initImage]
        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            await event(.progress(0.12 + (Double(index) * 0.075), "Preparing \(plan.name)"))
            let image: Containerization.Image
            if let cached = try? await store.get(reference: plan.image) {
                image = cached
            } else {
                try DiskSafety.require(at: dataRoot, additional: Int64(1.gib()))
                image = try await store.get(reference: plan.image, pull: true)
            }
            protectedImages.insert(image.reference)
            try Task.checkCancellation()
            rootfs[plan.name] = try await prepareRootfs(
                image: image,
                digest: image.digest,
                at: serviceRoot.appendingPathComponent("\(plan.name).ext4")
            )
            let imageDocument = try await image.config(for: .current)
            var process = LinuxProcessConfiguration(from: imageDocument.config ?? ImageConfig())
            if !process.environmentVariables.contains(where: { $0.hasPrefix("PATH=") }) {
                process.environmentVariables.append("PATH=" + LinuxProcessConfiguration.defaultPath)
            }
            process.environmentVariables = plan.environment.merging(imageEnvironment: process.environmentVariables)
            if let command = plan.command {
                process.arguments = (imageDocument.config?.entrypoint ?? []) + command
            }
            processConfigs[plan.name] = process
            await event(.log("Prepared \(plan.name) from \(short(plan.image))"))
        }

        await event(.progress(0.59, "Preparing persistent private volumes"))
        // v5 and earlier created unjournaled volume images. Keep those files in
        // place as a recoverable backup and start v6 in a crash-resilient,
        // journaled volume namespace.
        let volumeRoot = dataRoot.appendingPathComponent("volumes-journaled-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeRoot, withIntermediateDirectories: true)
        let volumes: [(String, UInt64)] = [
            ("platform-data", 2.gib()),
            ("redis-data", 512.mib()),
            ("qdrant-data", 2.gib()),
            ("garage-data", 2.gib())
        ]
        var podVolumes: [LinuxPod.PodVolume] = []
        for (name, size) in volumes {
            try Task.checkCancellation()
            let path = volumeRoot.appendingPathComponent("\(name).ext4")
            try await prepareVolume(at: path, size: size)
            podVolumes.append(.init(name: name, source: .diskImage(path: path), format: "ext4"))
        }

        let identifier = "private-oci-" + UUID().uuidString.lowercased().prefix(8)
        let guestInterface = try CIDRv4("\(Self.bootstrapAddress)/24")
        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: kernelURL, platform: .linuxArm),
            initialFilesystem: initfs
        )
        let pod = try LinuxPod(String(identifier), vmm: vmm) { configuration in
            configuration.cpus = 4
            configuration.memoryInBytes = 4.gib()
            configuration.hostname = "private-oci-stack"
            configuration.bootLog = .file(path: dataRoot.appendingPathComponent("pod-boot.log"))
            configuration.interfaces = [NATInterface(
                ipv4Address: guestInterface,
                ipv4Gateway: nil
            )]
            // DHCP replaces this non-routable bootstrap address before
            // workloads run. No gateway or resolver is guessed here.
            configuration.dns = DNS(nameservers: [])
            var entries = Hosts.default.entries
            entries.append(.init(ipAddress: "127.0.0.1", hostnames: serviceNames + ["cbk.localhost", "cbk-storage.localhost", "cbk-relay.localhost", "cbk-apps.localhost", "cbk-labs.localhost"]))
            configuration.hosts = Hosts(entries: entries)
            configuration.volumes = podVolumes
        }

        for plan in plans {
            try Task.checkCancellation()
            guard let mount = rootfs[plan.name], var configuredProcess = processConfigs[plan.name] else {
                throw AppRuntimeError("The \(plan.name) service was not prepared.")
            }
            let serviceName = plan.name == "network-init" ? "runtime" : plan.name
            let output = MemoryWriter { lines in
                Task { @MainActor in event(.containerLines(serviceName, lines)) }
            }
            configuredProcess.stdout = output
            configuredProcess.stderr = output
            if plan.name == "network-init" {
                var capabilities = configuredProcess.capabilities
                capabilities.bounding.append(.netAdmin)
                capabilities.effective.append(.netAdmin)
                capabilities.permitted.append(.netAdmin)
                configuredProcess.capabilities = capabilities
            }
            if ["db-init", "garage-init", "platform"].contains(plan.name) {
                let originalArguments = configuredProcess.arguments
                if plan.name == "platform" {
                    // The image normally runs as uid/gid 1001. Use root only
                    // for the resolver copy, then irreversibly drop back to
                    // the image's account before its entrypoint executes.
                    configuredProcess.user = .init()
                    configuredProcess.arguments = [
                        "sh", "-c",
                        "cp /data/.private-network-resolv.conf /etc/resolv.conf && exec setpriv --reuid=1001 --regid=1001 --init-groups -- \"$@\"",
                        "private-network"
                    ] + originalArguments
                } else {
                    configuredProcess.arguments = [
                        "sh", "-c",
                        "cp /data/.private-network-resolv.conf /etc/resolv.conf && exec \"$@\"",
                        "private-network"
                    ] + originalArguments
                }
            }
            let process = configuredProcess
            outputs[plan.name] = output
            try await pod.addContainer(plan.name, rootfs: mount) { configuration in
                configuration.process = process
                configuration.hostname = plan.name
                configuration.memoryInBytes = plan.name == "platform" ? 2.gib() : 768.mib()
                for item in plan.mounts {
                    configuration.mounts.append(.sharedMount(name: item.name, destination: item.destination))
                }
                if let file = plan.fileMount {
                    configuration.mounts.append(.share(source: file.source, destination: file.destination, options: ["ro"]))
                }
            }
        }

        do {
            await event(.phase(.creating))
            await event(.progress(0.65, "Creating one private Linux pod"))
            try await pod.create()
            self.pod = pod
            try Task.checkCancellation()
            await event(.containerLines("runtime", ["Starting private DHCP network configuration"]))

            await event(.phase(.starting))
            try await runOneShot("network-init", in: pod, event: event, progress: 0.69)
            try await runOneShot("db-init", in: pod, event: event, progress: 0.72)
            try await startHealthy("redis", in: pod, command: ["redis-cli", "ping"], event: event, progress: 0.77)
            try await startHealthy("qdrant", in: pod, command: ["bash", "-c", ": > /dev/tcp/127.0.0.1/6333"], event: event, progress: 0.82)
            try await startHealthy("garage", in: pod, command: ["/garage", "-c", "/etc/garage.toml", "status"], event: event, progress: 0.87)
            try await runOneShot("garage-init", in: pod, event: event, progress: 0.91)
            try await startHealthy(
                "platform",
                in: pod,
                command: ["node", "-e", "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"],
                event: event,
                progress: 0.96,
                attempts: 180
            )
            await event(.progress(0.985, "Publishing the private platform"))
            try await installHTTPBridge(in: pod, hostSocket: hostSocket, ports: bridgePorts, event: event)
            await event(.log("VM socket relay is serving localhost:\(hostPort)"))

            await event(.progress(1, "Opening ChatBotKit Studio"))
            try Task.checkCancellation()
            try JSONEncoder().encode(protectedImages.sorted()).write(to: dataRoot.appendingPathComponent("protected-images.json"), options: .atomic)
            return StackInfo(
                url: URL(string: "http://127.0.0.1:\(hostPort)/")!,
                podID: String(identifier),
                dataRoot: dataRoot.path,
                sourceReference: bundle.sourceReference,
                resolvedDigest: bundle.resolvedDigest,
                composeYAML: bundle.composeYAML,
                publishedPort: hostPort
            )
        } catch {
            for name in serviceNames { await event(.service(name, .failed)) }
            let log = outputs.values.map { $0.text() }.joined(separator: "\n")
            if !log.isEmpty { await event(.log(String(log.suffix(1200)))) }
            throw error
        }
    }

    func stop() async throws -> [String] {
        forwarder?.stop()
        forwarder = nil
        for auxiliary in auxiliaryForwarders { auxiliary.stop() }
        auxiliaryForwarders.removeAll()
        var warnings: [String] = []
        if let pod {
            warnings = try await GracefulShutdown.run(
                started: startedServices,
                terminate: { name in
                    do { try await pod.killContainer(name, signal: .term) }
                    catch {
                        // A previously healthy service may already have exited.
                        guard (try? await pod.waitContainer(name, timeoutInSeconds: 1)) != nil else { throw error }
                    }
                },
                wait: { name, seconds in _ = try await pod.waitContainer(name, timeoutInSeconds: seconds) },
                force: { try await pod.killContainer($0, signal: .kill) },
                teardown: { try await pod.stop() }
            )
        }
        // Retain ownership if teardown throws so a retry can clean up the VM.
        pod = nil
        startedServices.removeAll()
        bridgeProcess = nil
        outputs.removeAll()
        storageLease?.release()
        storageLease = nil
        return warnings
    }

    func configuredModelCredentialKeys() async throws -> Set<String> {
        let output = try await runCredentialCommand(script: credentialStatusScript())
        return Set(try JSONDecoder().decode([String].self, from: output))
    }

    func updateModelCredentials(_ changes: [ModelCredentialChange]) async throws -> Set<String> {
        guard !changes.isEmpty else { return try await configuredModelCredentialKeys() }
        var seen: Set<String> = []
        for change in changes {
            guard ModelCredentialCatalog.managedKeys.contains(change.key), seen.insert(change.key).inserted else {
                throw AppRuntimeError("Studio refused an unsupported credential change.")
            }
            if let value = change.value {
                guard !value.isEmpty, value.utf8.count <= 16_384,
                      value.unicodeScalars.allSatisfy({ $0.value != 0 && $0.value != 10 && $0.value != 13 }) else {
                    throw AppRuntimeError("Studio refused an invalid credential value.")
                }
            }
        }
        let input = try JSONEncoder().encode(changes)
        guard input.count <= 64 * 1024 else {
            throw AppRuntimeError("The credential update is too large.")
        }
        let output = try await runCredentialCommand(script: credentialUpdateScript(), input: input)
        return Set(try JSONDecoder().decode([String].self, from: output))
    }

    private func credentialStatusScript() throws -> String {
        let keys = try String(
            decoding: JSONEncoder().encode(ModelCredentialCatalog.managedKeys.sorted()),
            as: UTF8.self
        )
        return "const managed=new Set(\(keys));" + #"""
        const fs=require('fs');
        const file='/data/config.env';
        const configured=()=>{
          if(!fs.existsSync(file)) return [];
          const found=new Set();
          for(const line of fs.readFileSync(file,'utf8').split(/\r?\n/)){
            const at=line.indexOf('=');
            if(at>0&&line.length>at+1&&managed.has(line.slice(0,at))) found.add(line.slice(0,at));
          }
          return Array.from(found).sort();
        };
        process.stdout.write(JSON.stringify(configured()));
        """#
    }

    private func credentialUpdateScript() throws -> String {
        let keys = try String(
            decoding: JSONEncoder().encode(ModelCredentialCatalog.managedKeys.sorted()),
            as: UTF8.self
        )
        return "const managed=new Set(\(keys));" + #"""
        const fs=require('fs');
        const file='/data/config.env';
        const fail=message=>{ console.error(message); process.exit(1); };
        try {
          const raw=fs.readFileSync(0,'utf8');
          if(Buffer.byteLength(raw,'utf8')>65536) fail('Credential update is too large.');
          const payload=JSON.parse(raw);
          if(!Array.isArray(payload)) fail('Credential update is invalid.');
          const changes=new Map();
          for(const item of payload){
            if(!item||typeof item.key!=='string'||!managed.has(item.key)||changes.has(item.key)) fail('Credential update contains an unsupported key.');
            if(item.value!==null&&(typeof item.value!=='string'||item.value.length===0||Buffer.byteLength(item.value,'utf8')>16384||/[\r\n\0]/.test(item.value))) fail('Credential update contains an invalid value.');
            changes.set(item.key,item.value);
          }
          let lines=fs.existsSync(file)?fs.readFileSync(file,'utf8').split(/\r?\n/):[];
          while(lines.length&&lines[lines.length-1]==='') lines.pop();
          lines=lines.filter(line=>{
            const at=line.indexOf('=');
            return at<=0||!changes.has(line.slice(0,at));
          });
          for(const [key,value] of changes){ if(value!==null) lines.push(key+'='+value); }
          fs.mkdirSync('/data',{recursive:true,mode:0o700});
          const temporary=file+'.studio-'+process.pid;
          try {
            fs.writeFileSync(temporary,lines.length?lines.join('\n')+'\n':'',{encoding:'utf8',mode:0o600});
            fs.chmodSync(temporary,0o600);
            fs.renameSync(temporary,file);
          } catch(error) {
            try { fs.unlinkSync(temporary); } catch {}
            throw error;
          }
          const found=new Set();
          for(const line of lines){
            const at=line.indexOf('=');
            if(at>0&&line.length>at+1&&managed.has(line.slice(0,at))) found.add(line.slice(0,at));
          }
          process.stdout.write(JSON.stringify(Array.from(found).sort()));
        } catch(error) {
          fail('Unable to update model credentials.');
        }
        """#
    }

    private func runCredentialCommand(script: String, input: Data? = nil) async throws -> Data {
        guard let pod, startedServices.contains("platform") else {
            throw AppRuntimeError("Start Studio’s platform before managing model providers.")
        }
        let stdout = MemoryWriter()
        let stderr = MemoryWriter()
        let process = try await pod.execInContainer(
            "platform",
            processID: "studio-credentials-" + UUID().uuidString.lowercased()
        ) { configuration in
            configuration.arguments = ["node", "-e", script]
            configuration.user = .init(uid: 1001, gid: 1001)
            configuration.capabilities = .init()
            configuration.noNewPrivileges = true
            configuration.stdin = input.map(OneShotDataReader.init)
            configuration.stdout = stdout
            configuration.stderr = stderr
        }
        let status = try await runProbe(process, timeout: 10)
        guard status.exitCode == 0 else {
            let detail = stderr.text().trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppRuntimeError(detail.isEmpty ? "Studio could not update model credentials." : detail)
        }
        return Data(stdout.text().utf8)
    }

    private func prepareInitfs(store: ImageStore, at path: URL) async throws -> Containerization.Mount {
        if FileManager.default.fileExists(atPath: path.path) {
            return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
        }
        try DiskSafety.require(at: path.deletingLastPathComponent(), additional: Int64(512.mib()))
        try await DiskSafety.replace(at: path) { staging in
            let image = try await store.getInitImage(reference: Self.initImage)
            _ = try await image.initBlock(at: staging, for: .linuxArm)
        }
        return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    private func prepareRootfs(image: Containerization.Image, digest: String, at path: URL) async throws -> Containerization.Mount {
        let stamp = path.appendingPathExtension("digest")
        let formatIdentity = digest + "\njournaled-v1"
        if FileManager.default.fileExists(atPath: path.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == formatIdentity {
            return .block(format: "ext4", source: path.path, destination: "/")
        }
        try DiskSafety.require(at: path.deletingLastPathComponent(), additional: Int64(4.gib()))
        try await DiskSafety.replace(at: path) { staging in
            _ = try await EXT4Unpacker(capacityInBytes: 4.gib(), journal: .default)
                .unpack(image, for: .current, at: staging)
        }
        // Disk first, identity second: interruption may cause a safe rebuild,
        // but can never label an old disk with the new image's identity.
        try formatIdentity.write(to: stamp, atomically: true, encoding: .utf8)
        return .block(format: "ext4", source: path.path, destination: "/")
    }

    private func prepareVolume(at path: URL, size: UInt64) async throws {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try DiskSafety.require(at: path.deletingLastPathComponent(), additional: Int64(size))
        try await DiskSafety.replace(at: path) { staging in
            let formatter = try EXT4.Formatter(
                FilePath(staging.absolutePath()),
                minDiskSize: size,
                journal: .default
            )
            try formatter.close()
        }
    }

    private func runOneShot(
        _ name: String,
        in pod: LinuxPod,
        event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void,
        progress: Double
    ) async throws {
        await event(.service(name, .starting))
        await event(.progress(progress, "Running \(name)"))
        try Task.checkCancellation()
        try await pod.startContainer(name)
        startedServices.insert(name)
        let status = try await pod.waitContainer(name, timeoutInSeconds: 180)
        startedServices.remove(name)
        guard status.exitCode == 0 else {
            throw AppRuntimeError("\(name) exited with code \(status.exitCode): \(outputs[name]?.text().suffix(800) ?? "")")
        }
        await event(.service(name, .complete))
        await event(.log("\(name) completed successfully"))
    }

    private func startHealthy(
        _ name: String,
        in pod: LinuxPod,
        command: [String],
        event: @MainActor @Sendable (RuntimeEvent) -> Void,
        progress: Double,
        attempts: Int = 60
    ) async throws {
        await event(.service(name, .starting))
        await event(.progress(progress, "Starting \(name)"))
        try Task.checkCancellation()
        try await pod.startContainer(name)
        startedServices.insert(name)
        var last = "not ready"
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let stdout = MemoryWriter()
            let stderr = MemoryWriter()
            do {
                let process = try await pod.execInContainer(name, processID: "health-\(name)-\(attempt)") { configuration in
                    configuration.arguments = command
                    configuration.stdout = stdout
                    configuration.stderr = stderr
                }
                let status = try await runProbe(process, timeout: 5)
                if status.exitCode == 0 {
                    await event(.service(name, .healthy))
                    await event(.log("\(name) is healthy"))
                    return
                }
                last = stderr.text()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                last = error.localizedDescription
            }
            // A failed probe can mean that the main service has already exited.
            // Wait briefly for that status and its drained logs instead of hiding
            // the cause behind another minute of failing exec calls.
            if let status = try? await pod.waitContainer(name, timeoutInSeconds: 1) {
                startedServices.remove(name)
                throw AppRuntimeError(StartupFailure.message(
                    service: name, output: outputs[name]?.text() ?? "",
                    fallback: last, exitCode: Int32(status.exitCode)
                ))
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AppRuntimeError(StartupFailure.message(
            service: name, output: outputs[name]?.text() ?? "", fallback: last
        ))
    }

    private func installHTTPBridge(
        in pod: LinuxPod,
        hostSocket: URL,
        ports: [UInt16],
        event: @escaping @MainActor @Sendable (RuntimeEvent) -> Void
    ) async throws {
        let script = """
        const fs=require('fs'),net=require('net');
        for(const port of \(ports)) {
        const path='/tmp/private-oci-http.sock'+(port===3000?'':'.'+port);
        try{fs.unlinkSync(path)}catch{}
        const server=net.createServer(client=>{
          const upstream=net.connect(port,'127.0.0.1');
          client.pipe(upstream);upstream.pipe(client);
          const close=()=>{client.destroy();upstream.destroy()};
          client.on('error',close);upstream.on('error',close);
        });
        server.listen(path);
        }
        setInterval(()=>{},2147483647);
        """
        let output = MemoryWriter { lines in
            Task { @MainActor in event(.containerLines("bridge", lines)) }
        }
        let process = try await pod.execInContainer("platform", processID: "localhost-bridge") { configuration in
            configuration.arguments = ["node", "-e", script]
            configuration.stdout = output
            configuration.stderr = output
        }
        try await process.start()
        bridgeProcess = process

        var socketReady = false
        for attempt in 0..<40 {
            try Task.checkCancellation()
            let check = try await pod.execInContainer("platform", processID: "bridge-check-\(attempt)") { configuration in
                configuration.arguments = ["node", "-e", "const fs=require('fs');process.exit(\(ports).every(p=>fs.existsSync('/tmp/private-oci-http.sock'+(p===3000?'':'.'+p)))?0:1)"]
            }
            let status = try await runProbe(check, timeout: 2)
            if status.exitCode == 0 { socketReady = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard socketReady else {
            throw AppRuntimeError("The private HTTP bridge did not start: \(output.text())")
        }
        for port in ports {
            let suffix = port == 3000 ? "" : ".\(port)"
            let destination = URL(filePath: hostSocket.path + suffix)
            // These sockets belong to this runtime, protected by its storage lease.
            if port != 3000 { try? FileManager.default.removeItem(at: destination) }
            try await pod.relayUnixSocket(
                "platform",
                socket: UnixSocketConfiguration(
                    source: URL(filePath: "/tmp/private-oci-http.sock" + suffix),
                    destination: destination,
                    direction: .outOf
                )
            )
        }
    }

    private func runProbe(_ process: LinuxProcess, timeout: Int64) async throws -> ExitStatus {
        try await ScopedProbe.run {
            try Task.checkCancellation()
            try await process.start()
            return try await process.wait(timeoutInSeconds: timeout)
        } cleanup: { failed in
            if failed {
                try? await process.kill(.kill)
                _ = try? await process.wait(timeoutInSeconds: 2)
            }
            try await process.delete()
        }
    }

    private func makePlans(bundle: OCIStackBundle, hostPort: UInt16, garageFile: URL) throws -> [ServicePlan] {
        let environments = try PrivateStackEnvironment.load(bundle.composeYAML, hostPort: hostPort)
        for name in serviceNames where environments[name] == nil {
            throw AppRuntimeError("Missing Compose service environment: \(name)")
        }
        let networkBootstrap = """
        set -eu
        ip address flush dev eth0
        ip route flush dev eth0 || true
        udhcpc -i eth0 -n -q -t 5 -T 2
        cp /etc/resolv.conf /data/.private-network-resolv.conf
        chmod 0644 /data/.private-network-resolv.conf
        echo "DHCP configured the private VM network"
        ip -4 address show dev eth0
        ip -4 route show
        cat /etc/resolv.conf
        nslookup binaries.prisma.sh
        echo "DNS preflight passed: binaries.prisma.sh"
        """
        return [
            .init(name: "network-init", image: bundle.images["redis"]!, environment: ComposeEnvironment(), command: ["sh", "-c", networkBootstrap], mounts: [("platform-data", "/data")], fileMount: nil),
            .init(name: "db-init", image: bundle.images["db-init"]!, environment: environments["db-init"]!, command: nil, mounts: [("platform-data", "/data")], fileMount: nil),
            .init(name: "redis", image: bundle.images["redis"]!, environment: environments["redis"]!, command: ["redis-server", "--appendonly", "yes"], mounts: [("redis-data", "/data")], fileMount: nil),
            .init(name: "qdrant", image: bundle.images["qdrant"]!, environment: environments["qdrant"]!, command: nil, mounts: [("qdrant-data", "/qdrant/storage")], fileMount: nil),
            .init(name: "garage", image: bundle.images["garage"]!, environment: environments["garage"]!, command: nil, mounts: [("garage-data", "/var/lib/garage")], fileMount: (garageFile.path, "/etc/garage.toml")),
            .init(name: "garage-init", image: bundle.images["garage-init"]!, environment: environments["garage-init"]!, command: ["node", "/garage-init.mjs"], mounts: [("platform-data", "/data")], fileMount: nil),
            .init(name: "platform", image: bundle.images["platform"]!, environment: environments["platform"]!, command: nil, mounts: [("platform-data", "/data")], fileMount: nil)
        ]
    }

    private func short(_ value: String) -> String {
        value.count > 42 ? String(value.prefix(42)) + "…" : value
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var phase: StackPhase = .idle
    @Published private(set) var services = Dictionary(uniqueKeysWithValues: serviceNames.map { ($0, ServicePhase.pending) })
    @Published private(set) var events = ["OCI source: \(defaultOCIReference)", "Runtime is private to this app"]
    @Published private(set) var containerLogs: [ContainerLogEntry] = []
    @Published private(set) var startupProgress = 0.0
    @Published private(set) var startupDetail = "Preparing your workspace"
    @Published private(set) var storageReport: StorageReport?
    @Published private(set) var storageError: String?
    @Published private(set) var storageBusy = false
    @Published private(set) var configuredModelCredentialKeys: Set<String> = []
    @Published private(set) var modelCredentialsError: String?
    @Published private(set) var modelCredentialsNotice: String?
    @Published private(set) var modelCredentialsBusy = false
    private var storageTask: Task<Void, Never>?
    private var modelCredentialsTask: Task<Void, Never>?
    private var modelCredentialsNoticeTask: Task<Void, Never>?
    private let runtime: any StackRuntime
    private let resources: @MainActor () throws -> (kernel: URL, data: URL)
    private var task: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var generation = UUID()
    private(set) var isShuttingDown = false
    private(set) var hasCompletedShutdown = false

    init(
        runtime: any StackRuntime = PrivateOCIStackRuntime(),
        resources: @escaping @MainActor () throws -> (kernel: URL, data: URL) = {
            guard let kernel = Bundle.main.url(forResource: "vmlinux-arm64", withExtension: nil, subdirectory: "Runtime") else {
                throw AppRuntimeError("The bundled Linux kernel is missing.")
            }
            return (kernel, try AppModel.privateDataRoot())
        }
    ) {
        self.runtime = runtime
        self.resources = resources
    }

    var info: StackInfo? {
        if case let .ready(info) = phase { return info }
        return nil
    }

    func start() {
        // A restored or auxiliary window may ask the shared model to start.
        // Only the initial idle state is allowed to create the private pod.
        guard case .idle = phase, !isShuttingDown, !storageBusy, !modelCredentialsBusy, !RuntimeSmokeTest.requested else { return }
        phase = .resolving
        generation = UUID()
        let run = generation
        containerLogs.append(.init(service: "runtime", message: "—— starting \(defaultOCIReference) ——"))
        services = Dictionary(uniqueKeysWithValues: serviceNames.map { ($0, .pending) })
        events = ["OCI source: \(defaultOCIReference)", "Runtime is private to this app"]
        startupProgress = 0
        startupDetail = "Preparing your workspace"
        task = Task {
            defer { if generation == run { task = nil } }
            do {
                try Task.checkCancellation()
                let paths = try resources()
                let info = try await runtime.start(kernelURL: paths.kernel, dataRoot: paths.data) { [weak self] event in
                    guard let self, self.generation == run, !self.isShuttingDown else { return }
                    self.apply(event)
                }
                try Task.checkCancellation()
                guard generation == run else { return }
                phase = .ready(info)
            } catch is CancellationError {
                if generation == run { phase = .idle }
            } catch {
                guard generation == run else { return }
                phase = .failed(error.localizedDescription)
                appendContainerLines(service: "runtime", lines: ["Error: \(diagnosticDescription(for: error))"])
                append("Error: \(error.localizedDescription)")
            }
        }
    }

    func restart(cleanup: StorageReport? = nil) {
        guard !phase.busy, !isShuttingDown, !storageBusy, !modelCredentialsBusy else { return }
        let previous = task
        previous?.cancel()
        generation = UUID()
        let run = generation
        phase = .stopping
        startupProgress = 0.02
        startupDetail = "Stopping the current stack"
        task = Task {
            defer { if generation == run { task = nil } }
            await previous?.value
            guard !Task.isCancelled, generation == run else { return }
            do {
                let warnings = try await runtime.stop()
                guard !Task.isCancelled, generation == run else { return }
                appendContainerLines(service: "runtime", lines: warnings)
                if let cleanup {
                    let summary = try await StorageMaintenance.clean(root: resources().data, preview: cleanup)
                    appendContainerLines(service: "runtime", lines: [summary])
                    storageReport = nil
                    try Task.checkCancellation()
                }
                services = services.mapValues { _ in .stopped }
                phase = .idle
                start()
            } catch {
                guard generation == run else { return }
                phase = .failed(error.localizedDescription)
                appendContainerLines(service: "runtime", lines: [error.localizedDescription])
            }
        }
    }

    func openInBrowser() {
        if let url = info?.url { NSWorkspace.shared.open(url) }
    }

    func clearLogs() {
        containerLogs.removeAll(keepingCapacity: true)
    }

    func inspectStorage() {
        guard !phase.busy, !isShuttingDown, !storageBusy, !modelCredentialsBusy else { return }
        storageBusy = true
        storageError = nil
        let digest = info?.resolvedDigest
        storageTask = Task {
            defer { storageBusy = false; storageTask = nil }
            do { storageReport = try await StorageMaintenance.inspect(root: resources().data, activeDigest: digest) }
            catch { storageError = error.localizedDescription }
        }
    }

    func inspectModelCredentials() {
        modelCredentialsNoticeTask?.cancel()
        modelCredentialsNoticeTask = nil
        modelCredentialsNotice = nil
        guard info != nil, !phase.busy, !isShuttingDown, !storageBusy, !modelCredentialsBusy else { return }
        modelCredentialsBusy = true
        modelCredentialsError = nil
        modelCredentialsTask = Task {
            defer { modelCredentialsBusy = false; modelCredentialsTask = nil }
            do {
                configuredModelCredentialKeys = try await runtime.configuredModelCredentialKeys()
            } catch is CancellationError {
                return
            } catch {
                modelCredentialsError = error.localizedDescription
            }
        }
    }

    func updateModelCredentials(_ changes: [ModelCredentialChange]) {
        guard info != nil, !phase.busy, !isShuttingDown, !storageBusy, !modelCredentialsBusy else { return }
        modelCredentialsNoticeTask?.cancel()
        modelCredentialsNoticeTask = nil
        modelCredentialsBusy = true
        modelCredentialsError = nil
        modelCredentialsNotice = nil
        modelCredentialsTask = Task {
            defer { modelCredentialsBusy = false; modelCredentialsTask = nil }
            do {
                configuredModelCredentialKeys = try await runtime.updateModelCredentials(changes)
                let notice = "Saved. Changes will be available shortly."
                modelCredentialsNotice = notice
                modelCredentialsNoticeTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard self?.modelCredentialsNotice == notice else { return }
                    self?.modelCredentialsNotice = nil
                    self?.modelCredentialsNoticeTask = nil
                }
            } catch is CancellationError {
                return
            } catch {
                modelCredentialsError = error.localizedDescription
            }
        }
    }

    func shutdown() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        isShuttingDown = true
        generation = UUID()
        phase = .stopping
        let previous = task
        previous?.cancel()
        let inspection = storageTask
        inspection?.cancel()
        let credentials = modelCredentialsTask
        credentials?.cancel()
        modelCredentialsNoticeTask?.cancel()
        modelCredentialsNoticeTask = nil
        modelCredentialsNotice = nil
        let operation = Task { @MainActor in
            // Await cancellation/cleanup before touching the runtime again.
            await previous?.value
            await inspection?.value
            await credentials?.value
            do {
                let warnings = try await runtime.stop()
                appendContainerLines(service: "runtime", lines: warnings)
                services = services.mapValues { _ in .stopped }
                phase = .idle
                hasCompletedShutdown = true
                return true
            } catch {
                phase = .failed(error.localizedDescription)
                appendContainerLines(service: "runtime", lines: [error.localizedDescription])
                return false
            }
        }
        shutdownTask = operation
        let succeeded = await operation.value
        task = nil
        if !succeeded {
            isShuttingDown = false
            shutdownTask = nil
        }
        return succeeded
    }

    func recoverFromAbortedUpdate() {
        guard hasCompletedShutdown else { return }
        hasCompletedShutdown = false
        isShuttingDown = false
        shutdownTask = nil
        phase = .failed("The update was interrupted. Choose Stack → Restart Stack to reopen your workspace.")
    }

    private func apply(_ event: RuntimeEvent) {
        switch event {
        case let .phase(value): phase = value
        case let .service(name, value): services[name] = value
        case let .progress(value, detail): startupProgress = value; startupDetail = detail
        case let .log(message): append(message)
        case let .containerLines(service, lines): appendContainerLines(service: service, lines: lines)
        }
    }

    private func appendContainerLines(service: String, lines: [String]) {
        let ansiPattern = String(UnicodeScalar(27)) + "\\[[0-9;]*[A-Za-z]"
        let clean = lines.map {
            $0.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
        containerLogs.append(contentsOf: clean.map { .init(service: service, message: $0) })
        if containerLogs.count > 8_000 {
            containerLogs.removeFirst(containerLogs.count - 8_000)
        }
    }

    private func append(_ message: String) {
        events.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)")
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }

    private func diagnosticDescription(for error: Error) -> String {
        let localized = error.localizedDescription
        let reflected = String(reflecting: error)
        return reflected.contains(localized) ? reflected : "\(localized) [\(reflected)]"
    }

    private static func privateDataRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppRuntimeError("Application Support is unavailable.")
        }
        let root = base.appendingPathComponent("PrivateOCIStack/Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// MARK: - Embedded live platform

@MainActor
final class EmbeddedWebInspector {
    static let shared = EmbeddedWebInspector()
    private let webViews = NSHashTable<WKWebView>.weakObjects()

    private init() {}

    func attach(_ webView: WKWebView) {
        webViews.add(webView)
    }

    func detach(_ webView: WKWebView) {
        webViews.remove(webView)
    }

    private var activeWebView: WKWebView? {
        let views = webViews.allObjects
        return views.first(where: { $0.window === NSApp.keyWindow })
            ?? views.first(where: { $0.window?.isMainWindow == true })
            ?? views.last
    }

    func reload() {
        activeWebView?.reload()
    }

    func show() {
        guard let webView = activeWebView else { return }
        webView.window?.makeKeyAndOrderFront(nil)
        webView.window?.makeFirstResponder(webView)

        // isInspectable is the public opt-in. WebKit currently exposes the
        // actual inspector window through these runtime selectors on macOS.
        // Keeping the selector lookup guarded avoids coupling the build to SPI.
        let inspectorSelector = NSSelectorFromString("_inspector")
        let showSelector = NSSelectorFromString("show")
        let showConsoleSelector = NSSelectorFromString("showConsole")
        guard webView.responds(to: inspectorSelector),
              let value = webView.perform(inspectorSelector),
              let inspector = value.takeUnretainedValue() as? NSObject,
              inspector.responds(to: showSelector) else { return }
        inspector.perform(showSelector)
        if inspector.responds(to: showConsoleSelector) {
            inspector.perform(showConsoleSelector)
        }
    }
}

struct EmbeddedWebView: NSViewRepresentable {
    let url: URL
    let colorScheme: ColorScheme
    let onEdgeColors: @MainActor (NSColor, NSColor) -> Void
    let onReady: @MainActor () -> Void
    var onOpenInternalWindow: @MainActor (URL) -> Bool = { _ in false }
    var onLoading: @MainActor () -> Void = {}
    var onFailure: @MainActor (String) -> Void = { _ in }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let externalBrowserWindows: ExternalBrowserWindowDelegate
        var loaded: URL?
        private weak var observedWebView: WKWebView?
        private var themeColorObservation: NSKeyValueObservation?
        private var underPageColorObservation: NSKeyValueObservation?
        private var sampledTopEdgeColor: NSColor?
        private var derivedPageBackgroundColor = NSColor.windowBackgroundColor
        private var appearanceIsDark: Bool?
        private var appearanceSampleTask: Task<Void, Never>?
        private var lastTopLeft: NSColor?
        private var lastBottomRight: NSColor?
        let onEdgeColors: @MainActor (NSColor, NSColor) -> Void
        let onReady: @MainActor () -> Void
        let onLoading: @MainActor () -> Void
        let onFailure: @MainActor (String) -> Void
        private var activeNavigation: WKNavigation?
        private var hasFinishedDocument = false
        private lazy var readiness = WebPageLoad { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading: self.onLoading()
            case .ready: self.onReady()
            case .failed(let message): self.onFailure(message)
            }
        }
        init(
            onEdgeColors: @escaping @MainActor (NSColor, NSColor) -> Void,
            onReady: @escaping @MainActor () -> Void,
            onOpenInternalWindow: @escaping @MainActor (URL) -> Bool = { _ in false },
            onLoading: @escaping @MainActor () -> Void = {},
            onFailure: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.externalBrowserWindows = ExternalBrowserWindowDelegate(
                openInternalURL: onOpenInternalWindow
            )
            self.onEdgeColors = onEdgeColors
            self.onReady = onReady
            self.onLoading = onLoading
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === activeNavigation else { return }
            hasFinishedDocument = true
            publishColors(from: webView)
            readiness.documentFinished()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            activeNavigation = navigation
            readiness.begin()
            sampledTopEdgeColor = nil
            webView.underPageBackgroundColor = nil
            derivedPageBackgroundColor = webView.underPageBackgroundColor
                ?? NSColor.windowBackgroundColor
            publishColors(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation, error: error)
        }

        private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
            guard navigation === activeNavigation else { return }
            let error = error as NSError
            if hasFinishedDocument, error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                // A declined beforeunload prompt keeps the existing document.
                readiness.documentFinished()
                return
            }
            readiness.fail(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard observedWebView === webView else { return }
            externalBrowserWindows.confirmations.cancelPending()
            hasFinishedDocument = false
            readiness.fail("The web page process stopped. Your container stack is still running; reload the page to reconnect.")
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.topEdgeMessageName,
                  message.frameInfo.isMainFrame,
                  let components = message.body as? [NSNumber],
                  components.count == 4,
                  components.prefix(3).allSatisfy({ $0.doubleValue.isFinite && (0...255).contains($0.doubleValue) }),
                  components[3].doubleValue.isFinite, (0...1).contains(components[3].doubleValue) else { return }
            // CSS computed colors are defined in sRGB. Preserve that color
            // space explicitly so AppKit does not shift the sampled shade.
            let color = NSColor(
                srgbRed: CGFloat(truncating: components[0]) / 255,
                green: CGFloat(truncating: components[1]) / 255,
                blue: CGFloat(truncating: components[2]) / 255,
                alpha: CGFloat(truncating: components[3])
            )
            guard !Self.nearlyEqual(color, sampledTopEdgeColor) else { return }
            sampledTopEdgeColor = color
            if let observedWebView {
                // This is WebKit's public backdrop for the area revealed when
                // the document rubber-bands beyond its bounds. Lock it to the
                // same one-shot top-edge color so the title region continues
                // seamlessly into top overscroll.
                observedWebView.underPageBackgroundColor = color
                publishColors(from: observedWebView)
            }
        }

        func startColorObservation(in webView: WKWebView) {
            externalBrowserWindows.confirmations.onActivityChanged = { [weak self] active in
                self?.readiness.setConfirmationActive(active)
            }
            stopColorObservation()
            observedWebView = webView
            derivedPageBackgroundColor = webView.underPageBackgroundColor
                ?? NSColor.windowBackgroundColor
            themeColorObservation = webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self, weak webView] in
                    if let self, let webView { self.publishColors(from: webView) }
                }
            }
            underPageColorObservation = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] webView, _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    if self.sampledTopEdgeColor == nil {
                        self.derivedPageBackgroundColor = webView.underPageBackgroundColor
                            ?? NSColor.windowBackgroundColor
                    }
                    self.publishColors(from: webView)
                }
            }
            publishColors(from: webView)
        }

        func recordAppearance(isDark: Bool) {
            appearanceIsDark = isDark
        }

        func appearanceDidChange(isDark: Bool, in webView: WKWebView) {
            guard appearanceIsDark != isDark else { return }
            appearanceIsDark = isDark
            appearanceSampleTask?.cancel()
            appearanceSampleTask = Task { @MainActor [weak webView] in
                // Let WebKit repaint the document for its new effective
                // appearance before asking the one-shot edge sampler to run.
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let webView else { return }
                _ = try? await webView.evaluateJavaScript(
                    "window.__privateOCIStackSampleTopEdgeColor?.()"
                )
            }
        }

        func stopColorObservation() {
            readiness.invalidate()
            activeNavigation = nil
            appearanceSampleTask?.cancel()
            appearanceSampleTask = nil
            themeColorObservation?.invalidate()
            underPageColorObservation?.invalidate()
            themeColorObservation = nil
            underPageColorObservation = nil
            observedWebView = nil
        }

        private func publishColors(from webView: WKWebView) {
            let pageBackground = derivedPageBackgroundColor
            // Safari's own toolbar can use an internal sampled top-edge color
            // that public WKWebView does not expose. Prefer our stable DOM edge
            // sample, then fall back to WebKit's declared theme/background.
            let titleColor = sampledTopEdgeColor ?? webView.themeColor ?? pageBackground
            guard !Self.nearlyEqual(titleColor, lastTopLeft)
                    || !Self.nearlyEqual(pageBackground, lastBottomRight) else { return }
            lastTopLeft = titleColor
            lastBottomRight = pageBackground
            onEdgeColors(titleColor, pageBackground)
        }

        private static func nearlyEqual(_ lhs: NSColor, _ rhs: NSColor?) -> Bool {
            guard let lhs = lhs.usingColorSpace(.deviceRGB),
                  let rhs = rhs?.usingColorSpace(.deviceRGB) else { return false }
            return abs(lhs.redComponent - rhs.redComponent) < 0.01
                && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
                && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
                && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
        }

        static let topEdgeMessageName = "privateOCIStackTopEdgeColor"

        static let topEdgeColorScript = #"""
        (() => {
          if (window.__privateOCIStackTopEdgeColorInstalled) return;
          window.__privateOCIStackTopEdgeColorInstalled = true;

          const handler = window.webkit?.messageHandlers?.privateOCIStackTopEdgeColor;
          if (!handler) return;

          const rgba = (value) => {
            const match = value?.match(/^rgba?\(\s*([\d.]+)[, ]+\s*([\d.]+)[, ]+\s*([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$/i);
            if (!match) return null;
            const alpha = match[4] === undefined ? 1 : Number(match[4]);
            if (alpha < 0.05) return null;
            return [Math.round(Number(match[1])), Math.round(Number(match[2])), Math.round(Number(match[3])), alpha];
          };

          const colorAt = (x) => {
            for (const element of document.elementsFromPoint(x, 1)) {
              const rect = element.getBoundingClientRect();
              if (rect.width < 2 || rect.height < 2) continue;
              const color = rgba(getComputedStyle(element).backgroundColor);
              // Ignore translucent viewport overlays such as modal dimmers;
              // they are not the page edge's persistent background.
              if (color && color[3] >= 0.95) return color;
            }
            return null;
          };

          const sample = () => {
            const width = Math.max(1, document.documentElement.clientWidth);
            const points = [0.02, 0.14, 0.32, 0.5, 0.68, 0.86, 0.98];
            const colors = points.map((fraction) => colorAt(Math.min(width - 1, Math.max(1, width * fraction)))).filter(Boolean);
            if (!colors.length) return;

            const groups = new Map();
            for (const color of colors) {
              const key = `${Math.round(color[0] / 4)},${Math.round(color[1] / 4)},${Math.round(color[2] / 4)},${Math.round(color[3] * 20)}`;
              const group = groups.get(key) || { count: 0, color };
              group.count += 1;
              groups.set(key, group);
            }
            const winner = [...groups.values()].sort((a, b) => b.count - a.count)[0];
            if (!winner || winner.count < Math.ceil(points.length / 2)) return;
            handler.postMessage(winner.color);
          };

          // Take one settled sample for this document. Transient modal
          // backdrops, animations, DOM mutations, and scroll bounce must not
          // recolor the native title region after navigation has completed.
          let appearanceSampleTimer = 0;
          const sampleAfterAppearanceSettles = () => {
            clearTimeout(appearanceSampleTimer);
            appearanceSampleTimer = setTimeout(
              () => requestAnimationFrame(sample),
              120
            );
          };
          window.__privateOCIStackSampleTopEdgeColor = sampleAfterAppearanceSettles;
          sampleAfterAppearanceSettles();

          // App-managed theme switches commonly update a class or data value
          // on <html> without navigating or changing macOS appearance. Watch
          // only those root theme signals. Subtree mutations (including modal
          // presentation), body scroll locks, and animation styles are ignored.
          new MutationObserver(sampleAfterAppearanceSettles).observe(
            document.documentElement,
            {
              attributes: true,
              attributeFilter: [
                "class",
                "data-theme",
                "data-color-scheme",
                "data-mode",
                "data-appearance"
              ]
            }
          );
          if (document.body) {
            new MutationObserver(sampleAfterAppearanceSettles).observe(
              document.body,
              {
                attributes: true,
                attributeFilter: [
                  "data-theme",
                  "data-color-scheme",
                  "data-mode",
                  "data-appearance"
                ]
              }
            );
          }
        })();
        """#
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onEdgeColors: onEdgeColors,
            onReady: onReady,
            onOpenInternalWindow: onOpenInternalWindow,
            onLoading: onLoading,
            onFailure: onFailure
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.topEdgeMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Coordinator.topEdgeColorScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let view = Self.makeContentWebView(configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator.externalBrowserWindows
        view.isInspectable = true
        // Begin with WebKit's derived <html>/<body> background. Once the
        // document's top-edge color is sampled, the coordinator overrides
        // this public property to make top overscroll continue the title bar.
        view.underPageBackgroundColor = nil
        applyAppearance(to: view)
        context.coordinator.recordAppearance(isDark: colorScheme == .dark)
        EmbeddedWebInspector.shared.attach(view)
        context.coordinator.startColorObservation(in: view)
        view.load(URLRequest(url: url))
        context.coordinator.loaded = url
        return view
    }

    static func makeContentWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        // Window dragging belongs to WindowDragSurface. Keeping the content
        // view as a plain WKWebView ensures controls at every page edge receive
        // their mouse events; WKWebView uses flipped view coordinates.
        WKWebView(frame: .zero, configuration: configuration)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        applyAppearance(to: view)
        context.coordinator.appearanceDidChange(
            isDark: colorScheme == .dark,
            in: view
        )
        guard context.coordinator.loaded != url else { return }
        view.load(URLRequest(url: url))
        context.coordinator.loaded = url
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.externalBrowserWindows.confirmations.cancelPending()
        coordinator.stopColorObservation()
        EmbeddedWebInspector.shared.detach(view)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.topEdgeMessageName
        )
    }

    private func applyAppearance(to view: WKWebView) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

// MARK: - Interface

private let windowDragSurfaceIdentifier = NSUserInterfaceItemIdentifier("PrivateOCIStack.WindowDragSurface")

final class WindowDragSurface: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct WindowChromeInstaller: NSViewRepresentable {
    let pageIsReady: Bool
    let pageBackgroundColor: NSColor

    final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true

            DispatchQueue.main.async { [weak window] in
                guard let frameView = window?.contentView?.superview,
                      frameView.subviews.contains(where: { $0.identifier == windowDragSurfaceIdentifier }) == false else { return }
                let surface = WindowDragSurface(frame: NSRect(
                    x: 78,
                    y: max(0, frameView.bounds.height - 38),
                    width: max(0, frameView.bounds.width - 78),
                    height: 38
                ))
                surface.identifier = windowDragSurfaceIdentifier
                surface.autoresizingMask = [.width, .minYMargin]
                surface.setAccessibilityElement(false)
                frameView.addSubview(surface, positioned: .above, relativeTo: nil)
            }
        }
    }

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView(frame: .zero)
        updateWindow(for: view)
        return view
    }

    func updateNSView(_ view: InstallerView, context: Context) {
        updateWindow(for: view)
    }

    private func updateWindow(for view: InstallerView) {
        DispatchQueue.main.async { [weak window = view.window] in
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = pageIsReady ? pageBackgroundColor : StudioBrand.background
        }
    }
}

struct PageEdgeTitlebar: View {
    let pageIsReady: Bool
    let themeColor: NSColor

    var body: some View {
        Group {
            if pageIsReady {
                Color(nsColor: themeColor)
            } else {
                // Keep the native loading and failure surfaces coherent with
                // the current macOS appearance.
                Color(nsColor: StudioBrand.background)
            }
        }
            .frame(height: 38)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ServiceProgressRow: View {
    let name: String
    let phase: ServicePhase
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(phase.color).frame(width: 7, height: 7).shadow(color: phase.color.opacity(0.8), radius: 4)
            Text(name).font(.caption.weight(.medium))
            Spacer()
            Text(phase.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StartupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        StudioLaunchSurface(
            detail: model.startupDetail,
            progress: model.startupProgress,
            services: serviceNames.map { ($0, (model.services[$0] ?? .pending).title) }
        )
    }
}

struct FailureView: View {
    let message: String

    private var summary: String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return firstLine.count > 240 ? String(firstLine.prefix(240)) + "…" : firstLine
    }

    var body: some View {
        ZStack {
            Color(nsColor: StudioBrand.background)
            VStack(spacing: 16) {
                CBKLogo().frame(width: 52, height: 52).padding(.bottom, 12)
                Label("Studio couldn’t start", systemImage: "exclamationmark.circle")
                    .font(.title2.bold())
                Text(summary).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 620)
                Text("Open Stack → Show Live Logs for the complete container output.")
                    .font(.caption).foregroundStyle(.tertiary)
                Text("Choose Stack → Restart Stack to try again.").font(.caption).foregroundStyle(.tertiary)
            }.padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioPageWindow: Codable, Hashable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @SwiftUI.State private var pageReveal = WebPageRevealState()
    @SwiftUI.State private var pageError: String?
    @SwiftUI.State private var pageThemeColor = NSColor.windowBackgroundColor
    @SwiftUI.State private var pageBackgroundColor = NSColor.windowBackgroundColor

    init(model: AppModel) {
        self.model = model
    }
    var body: some View {
        VStack(spacing: 0) {
            PageEdgeTitlebar(pageIsReady: pageReveal.hasRevealedPage, themeColor: pageThemeColor)
            ZStack {
                Color(nsColor: pageReveal.hasRevealedPage ? pageBackgroundColor : StudioBrand.background)
                if let info = model.info {
                    EmbeddedWebView(
                        url: info.url,
                        colorScheme: colorScheme,
                        onEdgeColors: { themeColor, backgroundColor in
                            pageThemeColor = themeColor
                            pageBackgroundColor = backgroundColor
                        },
                        onReady: {
                            pageError = nil
                            pageReveal.documentBecameReady()
                        },
                        onOpenInternalWindow: { destination in
                            openWindow(value: StudioPageWindow(url: destination))
                            return true
                        },
                        onLoading: {
                            pageError = nil
                            pageReveal.documentStartedLoading()
                        },
                        onFailure: { pageError = $0 }
                    )
                    .opacity(pageReveal.hasRevealedPage ? 1 : 0)
                    .animation(.easeOut(duration: 0.7), value: pageReveal.hasRevealedPage)
                }
                if let pageError, model.info != nil {
                    VStack(spacing: 16) {
                        Label("The page couldn’t load", systemImage: "exclamationmark.circle").font(.title2)
                        Text(pageError).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Reload Page") { EmbeddedWebInspector.shared.reload() }
                        Text("The container stack has not been restarted.").font(.caption).foregroundStyle(.secondary)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: StudioBrand.background))
                } else if case let .failed(message) = model.phase {
                    FailureView(message: message)
                } else if !pageReveal.hasRevealedPage && !model.isShuttingDown {
                    StartupView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 980, minHeight: 680)
        .background(WindowChromeInstaller(
            pageIsReady: pageReveal.hasRevealedPage,
            pageBackgroundColor: pageBackgroundColor
        ))
        .onChange(of: model.info?.podID) { _, _ in
            // Shutdown also clears the pod ID. Retire the launch cover for
            // this window's lifetime, including quit and explicit restarts.
            pageError = nil
        }
        .task { if !RuntimeSmokeTest.requested { model.start() } }
    }
}

struct StudioPageView: View {
    let destination: StudioPageWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @SwiftUI.State private var pageReveal = WebPageRevealState()
    @SwiftUI.State private var pageError: String?
    @SwiftUI.State private var pageThemeColor = NSColor.windowBackgroundColor
    @SwiftUI.State private var pageBackgroundColor = NSColor.windowBackgroundColor
    @SwiftUI.State private var reloadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PageEdgeTitlebar(pageIsReady: pageReveal.hasRevealedPage, themeColor: pageThemeColor)
            ZStack {
                Color(nsColor: pageReveal.hasRevealedPage ? pageBackgroundColor : StudioBrand.background)
                EmbeddedWebView(
                    url: destination.url,
                    colorScheme: colorScheme,
                    onEdgeColors: { themeColor, backgroundColor in
                        pageThemeColor = themeColor
                        pageBackgroundColor = backgroundColor
                    },
                    onReady: {
                        pageError = nil
                        pageReveal.documentBecameReady()
                    },
                    onOpenInternalWindow: { url in
                        openWindow(value: StudioPageWindow(url: url))
                        return true
                    },
                    onLoading: { pageError = nil },
                    onFailure: { pageError = $0 }
                )
                .id(reloadID)
                .opacity(pageReveal.hasRevealedPage ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: pageReveal.hasRevealedPage)

                if let errorMessage = pageError {
                    VStack(spacing: 16) {
                        Label("The window couldn’t load", systemImage: "exclamationmark.circle")
                            .font(.title2)
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Reload") {
                            pageError = nil
                            reloadID = UUID()
                        }
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: StudioBrand.background))
                } else if !pageReveal.hasRevealedPage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowChromeInstaller(
            pageIsReady: pageReveal.hasRevealedPage,
            pageBackgroundColor: pageBackgroundColor
        ))
    }
}

struct StackDetailsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            ScrollView {
                Text(model.info?.composeYAML ?? defaultOCIReference)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(minWidth: 370)
            VStack(alignment: .leading, spacing: 14) {
                Label(model.phase.title, systemImage: model.info == nil ? "hourglass" : "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(model.info == nil ? Color.secondary : Color.green)
                if let info = model.info {
                    LabeledContent("URL", value: info.url.absoluteString)
                    LabeledContent("Local port", value: String(info.publishedPort))
                    LabeledContent("Pod", value: info.podID)
                    LabeledContent("OCI digest", value: info.resolvedDigest)
                    LabeledContent("Storage", value: info.dataRoot)
                }
                Divider()
                Text("Run Events").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: - Native console

struct NativeConsoleView: NSViewRepresentable {
    let entries: [ContainerLogEntry]
    let streamKey: String
    let followsOutput: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = scrollView.backgroundColor
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Live container output")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.update(
            textView: textView,
            entries: entries,
            streamKey: streamKey,
            followsOutput: followsOutput
        )
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var renderedCount = 0
        private var firstID: UUID?
        private var lastID: UUID?
        private var streamKey = ""
        private var wasFollowing = true

        private lazy var timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        func update(
            textView: NSTextView,
            entries: [ContainerLogEntry],
            streamKey newStreamKey: String,
            followsOutput: Bool
        ) {
            let canAppend = streamKey == newStreamKey
                && renderedCount <= entries.count
                && (renderedCount == 0 || (
                    firstID == entries.first?.id
                    && lastID == entries[renderedCount - 1].id
                ))

            if canAppend {
                if renderedCount < entries.count {
                    let addition = attributedLog(entries[renderedCount...])
                    textView.textStorage?.append(addition)
                }
            } else {
                textView.textStorage?.setAttributedString(attributedLog(entries[...]))
            }

            let contentChanged = renderedCount != entries.count || !canAppend
            renderedCount = entries.count
            firstID = entries.first?.id
            lastID = entries.last?.id
            streamKey = newStreamKey

            if followsOutput && (contentChanged || !wasFollowing) {
                textView.scrollToEndOfDocument(nil)
            }
            wasFollowing = followsOutput
        }

        private func attributedLog(_ entries: ArraySlice<ContainerLogEntry>) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            let timestampAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let messageAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]

            for entry in entries {
                let service = String(entry.service.prefix(11)).padding(toLength: 11, withPad: " ", startingAt: 0)
                result.append(NSAttributedString(
                    string: timeFormatter.string(from: entry.timestamp) + "  ",
                    attributes: timestampAttributes
                ))
                result.append(NSAttributedString(
                    string: service + "  ",
                    attributes: [.font: font, .foregroundColor: color(for: entry.service)]
                ))
                result.append(NSAttributedString(string: entry.message + "\n", attributes: messageAttributes))
            }
            return result
        }

        private func color(for service: String) -> NSColor {
            .secondaryLabelColor
        }
    }
}

struct LiveLogsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var selectedService = "all"
    @SwiftUI.State private var followsOutput = true

    private var sources: [String] { ["all", "runtime"] + serviceNames + ["bridge"] }
    private var visibleEntries: [ContainerLogEntry] {
        selectedService == "all" ? model.containerLogs : model.containerLogs.filter { $0.service == selectedService }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("SOURCES")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(sources, id: \.self) { source in
                            Button {
                                selectedService = source
                            } label: {
                                HStack(spacing: 9) {
                                    Circle().fill(color(for: source)).frame(width: 7, height: 7)
                                    Text(source == "all" ? "All services" : source)
                                    Spacer()
                                    Text(String(count(for: source))).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    selectedService == source ? Color.primary.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }.padding(.horizontal, 7)
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 230)
            .background(Color(nsColor: .controlBackgroundColor))

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle().fill(Color.primary).frame(width: 6, height: 6)
                    Text("LIVE CONTAINER OUTPUT").font(.caption.weight(.semibold)).tracking(1)
                    Text("\(visibleEntries.count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Follow", isOn: $followsOutput).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 16).frame(height: 46)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
                NativeConsoleView(
                    entries: visibleEntries,
                    streamKey: "\(selectedService)-\(colorScheme)",
                    followsOutput: followsOutput
                )
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func count(for source: String) -> Int {
        source == "all" ? model.containerLogs.count : model.containerLogs.lazy.filter { $0.service == source }.count
    }

    private func color(for source: String) -> Color {
        source == selectedService ? .primary : .secondary
    }
}

struct StackCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Binding var selectedSettingsTab: StudioSettingsTab
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                guard let url = model.info?.url else { return }
                openWindow(value: StudioPageWindow(url: url))
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.info == nil)
        }
        CommandMenu("Stack") {
            Button("Restart Stack") { model.restart() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.phase.busy)
            Button("Open in Browser") { model.openInBrowser() }.disabled(model.info == nil)
            Divider()
            Button("Show Live Logs") { openWindow(id: "live-logs") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show Stack Details") { openWindow(id: "stack-details") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Manage Storage") {
                selectedSettingsTab = .storage
                openSettings()
            }
            Divider()
            Button("Show Web Inspector") { EmbeddedWebInspector.shared.show() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.info == nil)
            Button("Reload Embedded Page") { EmbeddedWebInspector.shared.reload() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.info == nil)
            Divider()
            Button("Clear Captured Logs") { model.clearLogs() }
                .disabled(model.containerLogs.isEmpty)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
        guard RuntimeSmokeTest.requested else { return }
        Task {
            do {
                guard let kernel = Bundle.main.url(forResource: "vmlinux-arm64", withExtension: nil, subdirectory: "Runtime") else { throw AppRuntimeError("Smoke-test kernel is missing.") }
                try await RuntimeSmokeTest.run(kernel: kernel)
                print("STUDIO_SMOKE_PASS: SIGTERM, clean exit, persistent-volume marker, and VM teardown verified. Disposable runtime removed.")
                fflush(nil)
                finishSmokeTest()
            } catch {
                print("STUDIO_SMOKE_FAIL: \(error.localizedDescription)")
                fflush(nil)
                finishSmokeTest()
            }
        }
    }

    private func finishSmokeTest() {
        // terminateLater enters AppKit's nested termination event loop. Enter
        // it from the run loop, not while occupying the Swift main-actor queue,
        // so the normal asynchronous shutdown delegate can finish.
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle's normal relaunch path already awaited verified teardown.
        // Resumed installs and ordinary quits still use the same shutdown guard.
        if AppModel.shared.hasCompletedShutdown { return .terminateNow }
        Task {
            let stopped = await AppModel.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: stopped)
            if !stopped {
                let alert = NSAlert()
                alert.messageText = "Studio could not safely stop its stack"
                alert.informativeText = "The app has stayed open. Check Stack → Show Live Logs, then try quitting again."
                alert.runModal()
            }
        }
        return .terminateLater
    }
}

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @SwiftUI.State private var selectedSettingsTab = StudioSettingsTab.models
    var body: some Scene {
        Window("Studio", id: "main") {
            ContentView(model: model).tint(Color(nsColor: StudioBrand.foreground))
        }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
            .commands { StackCommands(model: model, selectedSettingsTab: $selectedSettingsTab) }
            .commands {
                CommandGroup(after: .appSettings) { CheckForUpdatesButton() }
            }
        WindowGroup("Studio", for: StudioPageWindow.self) { $destination in
            if let destination {
                StudioPageView(destination: destination)
                    .tint(Color(nsColor: StudioBrand.foreground))
            }
        }
            .defaultSize(width: 1100, height: 760)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
        Settings {
            StudioSettingsView(model: model, selection: $selectedSettingsTab)
        }
            .windowResizability(.contentSize)
        Window("Stack Details", id: "stack-details") {
            StackDetailsView(model: model).tint(Color(nsColor: StudioBrand.foreground))
        }
            .defaultSize(width: 940, height: 600)
        Window("Live Container Logs", id: "live-logs") {
            LiveLogsView(model: model).tint(Color(nsColor: StudioBrand.foreground))
        }
            .defaultSize(width: 1080, height: 680)
    }
}
