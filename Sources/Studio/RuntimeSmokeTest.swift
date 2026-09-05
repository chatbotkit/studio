import AppKit
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import Foundation
import SystemPackage

/// Explicit development-only invocation. Uses a new temporary directory, never
/// AppModel's production data root. Packaging instructions use a distinct bundle
/// identity so the live application cannot be reused by Launch Services.
enum RuntimeSmokeTest {
    static var requested: Bool {
        // Finder/UI tools may reopen the diagnostic without command-line args.
        // Its dedicated identity must never start the normal community stack.
        CommandLine.arguments.contains("--runtime-smoke-test") || Bundle.main.bundleIdentifier == "ai.cbk.studio.smoke-test"
    }
    private static func stage(_ message: String) { FileHandle.standardOutput.write(Data("STUDIO_SMOKE_STAGE: \(message)\n".utf8)) }

    static func run(kernel: URL) async throws {
        stage("Validating the packaged Sparkle configuration (no update check)")
        try await AppUpdater.shared.validateConfigurationForSmokeTest()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var safeToRemove = true
        defer { if safeToRemove { try? FileManager.default.removeItem(at: root) } }
        try DiskSafety.require(at: root, additional: 512 * 1_024 * 1_024)
        stage("Verifying the real public Compose artifact")
        _ = try await OCIComposeLoader.load(reference: "oci://ghcr.io/chatbotkit/platform-community:latest", cacheRoot: root.appendingPathComponent("artifacts"))
        stage("Preparing disposable VM images")
        let store = try ImageStore(path: root.appendingPathComponent("images"))
        let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.43.0")
        let initfs = try await initImage.initBlock(at: root.appendingPathComponent("initfs.ext4"), for: .linuxArm)
        let image = try await store.pull(reference: "docker.io/library/alpine:3.22", platform: .current)
        let serviceDisk = try await EXT4Unpacker(capacityInBytes: 256.mib(), journal: .default).unpack(image, for: .current, at: root.appendingPathComponent("service.ext4"))
        let checkerDisk = try await EXT4Unpacker(capacityInBytes: 256.mib(), journal: .default).unpack(image, for: .current, at: root.appendingPathComponent("checker.ext4"))
        let volume = root.appendingPathComponent("data.ext4")
        let formatter = try EXT4.Formatter(FilePath(volume.path), minDiskSize: 64.mib(), journal: .default)
        try formatter.close()
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm), initialFilesystem: initfs)
        let pod = try LinuxPod("studio-smoke-" + UUID().uuidString.prefix(8), vmm: vmm) { config in
            config.cpus = 2
            config.memoryInBytes = 512.mib()
            config.bootLog = .file(path: root.appendingPathComponent("boot.log"))
            config.volumes = [.init(name: "data", source: .diskImage(path: volume), format: "ext4")]
        }
        let output = MemoryWriter()
        try await pod.addContainer("platform", rootfs: serviceDisk) { config in
            config.process.arguments = ["/bin/sh", "-c", "trap 'echo graceful > /data/stopped; sync; exit 0' TERM; echo READY; while :; do sleep 1; done"]
            config.process.environmentVariables = ["PATH=" + LinuxProcessConfiguration.defaultPath]
            config.process.stdout = output; config.process.stderr = output
            config.mounts.append(.sharedMount(name: "data", destination: "/data"))
        }
        try await pod.addContainer("checker", rootfs: checkerDisk) { config in
            config.process.arguments = ["/bin/sh", "-c", "test \"$(cat /data/stopped)\" = graceful"]
            config.process.environmentVariables = ["PATH=" + LinuxProcessConfiguration.defaultPath]
            config.mounts.append(.sharedMount(name: "data", destination: "/data"))
        }
        do {
            safeToRemove = false
            stage("Booting the isolated VM")
            try await pod.create()
            try await pod.startContainer("platform")
            for _ in 0..<100 where !output.text().contains("READY") { try await Task.sleep(for: .milliseconds(50)) }
            guard output.text().contains("READY") else { throw AppRuntimeError("Smoke service did not become ready: \(output.text())") }
            stage("Verifying graceful exit and persistent-volume marker")
            let warnings = try await GracefulShutdown.run(
                started: ["platform"],
                terminate: { try await pod.killContainer($0, signal: .term) },
                wait: { name, seconds in
                    let status = try await pod.waitContainer(name, timeoutInSeconds: seconds)
                    guard status.exitCode == 0 else { throw AppRuntimeError("Smoke service did not exit cleanly.") }
                },
                force: { try await pod.killContainer($0, signal: .kill) },
                teardown: {
                    try await pod.startContainer("checker")
                    let status = try await pod.waitContainer("checker", timeoutInSeconds: 5)
                    guard status.exitCode == 0 else { throw AppRuntimeError("Graceful shutdown marker was not persisted to the volume.") }
                    try await pod.stop()
                }
            )
            safeToRemove = true
            guard warnings.isEmpty else { throw AppRuntimeError(warnings.joined(separator: "\n")) }
        } catch {
            if !safeToRemove {
                do { try await Task { try await pod.stop() }.value; safeToRemove = true }
                catch { throw AppRuntimeError("Smoke VM cleanup failed; disposable files preserved at \(root.path): \(error.localizedDescription)") }
            }
            throw error
        }
    }
}
