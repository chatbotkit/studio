import ContainerizationOCI
import Foundation

enum VerifiedComposeArtifact {
    static let objectLimit: Int64 = 2 * 1_024 * 1_024

    /// RegistryClient additionally caps response buffering at 4 MiB, including
    /// dishonest responses whose declared descriptor size is smaller.
    static func load(root: Descriptor, fetch: @Sendable (Descriptor) async throws -> Data) async throws -> (compose: Data, lock: Data) {
        func checked(_ descriptor: Descriptor) async throws -> Data {
            try Task.checkCancellation()
            guard descriptor.size > 0, descriptor.size <= objectLimit else {
                throw AppRuntimeError("OCI configuration object exceeds the 2 MiB limit or has an invalid size.")
            }
            let data = try await fetch(descriptor)
            try Task.checkCancellation()
            try OCIComposeLoader.verify(data, descriptor: descriptor)
            return data
        }
        let manifestData = try await checked(root)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.schemaVersion == 2,
              manifest.artifactType == "application/vnd.docker.compose.project" else {
            throw AppRuntimeError("The OCI object is not a supported Docker Compose project.")
        }
        guard manifest.layers.count <= 8 else { throw AppRuntimeError("The OCI project contains too many layers.") }
        let layers = manifest.layers.filter { $0.mediaType == "application/vnd.docker.compose.file+yaml" }
        guard layers.count == 2, layers[0].digest != layers[1].digest else {
            throw AppRuntimeError("The OCI project must contain two distinct YAML layers: Compose and its image lock.")
        }
        // Preflight all descriptors before fetching any YAML.
        guard layers.allSatisfy({ $0.size > 0 && $0.size <= objectLimit }) else {
            throw AppRuntimeError("OCI YAML exceeds the 2 MiB configuration limit.")
        }
        var data: [Data] = []
        var composeIndex: Int?
        var lockIndex: Int?
        for (index, layer) in layers.enumerated() {
            let bytes = try await checked(layer)
            guard let text = String(data: bytes, encoding: .utf8) else { throw AppRuntimeError("The OCI YAML is not valid UTF-8.") }
            data.append(bytes)
            let title = layer.annotations?["org.opencontainers.image.title"] ?? layer.annotations?["com.docker.compose.file"] ?? ""
            let distributions = ["platform-studio", "platform-community"]
            let hasPinnedApp = distributions.contains { text.contains("image: ghcr.io/chatbotkit/\($0)-app@sha256:") }
            let hasComposeHeader = distributions.contains { text.contains("\($0) distribution stack") }
            if title.contains("image-digests") || (title.isEmpty && hasPinnedApp) {
                guard lockIndex == nil else { throw AppRuntimeError("The OCI project contains ambiguous image-lock layers.") }
                lockIndex = index
            } else if title.contains("compose") || hasComposeHeader {
                guard composeIndex == nil else { throw AppRuntimeError("The OCI project contains ambiguous Compose layers.") }
                composeIndex = index
            }
        }
        // Unlabelled artifacts use their ordered layers. Never re-fetch fallback
        // bytes, and never assign the same verified layer to both roles.
        let compose = composeIndex ?? lockIndex.map { 1 - $0 } ?? 0
        let lock = lockIndex ?? (1 - compose)
        guard compose != lock else { throw AppRuntimeError("The OCI layer roles are ambiguous.") }
        return (data[compose], data[lock])
    }
}
