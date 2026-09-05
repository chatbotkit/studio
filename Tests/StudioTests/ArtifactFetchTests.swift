import ContainerizationOCI
import CryptoKit
import Foundation
import Testing
@testable import Studio

private func descriptor(_ data: Data, title: String? = nil, mediaType: String = "application/vnd.docker.compose.file+yaml") -> Descriptor {
    Descriptor(mediaType: mediaType, digest: "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: Int64(data.count), annotations: title.map { ["org.opencontainers.image.title": $0] })
}

private actor FakeRegistry {
    let objects: [String: Data]
    var calls: [String] = []
    init(_ objects: [String: Data]) { self.objects = objects }
    func fetch(_ descriptor: Descriptor) throws -> Data {
        calls.append(descriptor.digest)
        return try #require(objects[descriptor.digest])
    }
}

private func artifact(_ layers: [Descriptor], objects: [String: Data], type: String = "application/vnd.docker.compose.project") throws -> (Descriptor, FakeRegistry) {
    let manifest = Manifest(config: descriptor(Data("{}".utf8)), layers: layers, artifactType: type)
    let data = try JSONEncoder().encode(manifest)
    let root = descriptor(data, mediaType: "application/vnd.oci.image.manifest.v1+json")
    var values = objects; values[root.digest] = data
    return (root, FakeRegistry(values))
}

@Test func unlabelledArtifactFetchesEachVerifiedObjectExactlyOnce() async throws {
    let compose = Data("services: compose".utf8), lock = Data("services: digest-lock".utf8)
    let a = descriptor(compose), b = descriptor(lock)
    let (root, registry) = try artifact([a, b], objects: [a.digest: compose, b.digest: lock])
    let result = try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) }
    #expect(result.compose == compose)
    #expect(result.lock == lock)
    #expect(await registry.calls == [root.digest, a.digest, b.digest])
}

@Test func artifactLabelsWorkWithReversedLayerOrder() async throws {
    let compose = Data("project".utf8), lock = Data("lock".utf8)
    let a = descriptor(compose, title: "compose.yml"), b = descriptor(lock, title: "image-digests.yml")
    let (root, registry) = try artifact([b, a], objects: [a.digest: compose, b.digest: lock])
    let result = try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) }
    #expect(result.compose == compose && result.lock == lock)
}

@Test func corruptManifestIsRejectedBeforeDecodingOrFetchingLayers() async throws {
    let bytes = Data("manifest".utf8), root = descriptor(Data("different".utf8))
    let registry = FakeRegistry([root.digest: bytes])
    await #expect(throws: AppRuntimeError.self) { try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) } }
    #expect(await registry.calls == [root.digest])
}

@Test func corruptFallbackLayerIsNeverAccepted() async throws {
    let a = descriptor(Data("one".utf8)), b = descriptor(Data("two".utf8))
    let (root, registry) = try artifact([a, b], objects: [a.digest: Data("one".utf8), b.digest: Data("bad".utf8)])
    await #expect(throws: AppRuntimeError.self) { try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) } }
    #expect(await registry.calls == [root.digest, a.digest, b.digest])
}

@Test(arguments: [Int64(-1), 0, VerifiedComposeArtifact.objectLimit + 1])
func invalidManifestSizesNeverReachTransport(_ size: Int64) async {
    let root = Descriptor(mediaType: "manifest", digest: "sha256:" + String(repeating: "a", count: 64), size: size)
    await #expect(throws: AppRuntimeError.self) {
        try await VerifiedComposeArtifact.load(root: root) { _ in Issue.record("Unexpected fetch"); return Data() }
    }
}

@Test func ambiguousAndExcessiveLayersFailBeforeFetchingYAML() async throws {
    let a = descriptor(Data("one".utf8))
    for layers in [[a], [a, a], Array(repeating: a, count: 9)] {
        let (root, registry) = try artifact(layers, objects: [:])
        await #expect(throws: AppRuntimeError.self) { try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) } }
        #expect(await registry.calls == [root.digest])
    }
}

@Test func invalidUTF8AndDuplicateRoleLabelsAreRejected() async throws {
    for bytes in [Data([0xff]), Data("second".utf8)] {
        let aBytes = Data("first".utf8)
        let a = descriptor(aBytes, title: "compose.yml"), b = descriptor(bytes, title: "compose-extra.yml")
        let (root, registry) = try artifact([a, b], objects: [a.digest: aBytes, b.digest: bytes])
        await #expect(throws: AppRuntimeError.self) { try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) } }
    }
}

@Test func oversizedYAMLFailsBeforeAnyLayerDownload() async throws {
    let a = descriptor(Data("one".utf8))
    let b = Descriptor(mediaType: a.mediaType, digest: "sha256:" + String(repeating: "b", count: 64), size: VerifiedComposeArtifact.objectLimit + 1)
    let (root, registry) = try artifact([a, b], objects: [:])
    await #expect(throws: AppRuntimeError.self) { try await VerifiedComposeArtifact.load(root: root) { try await registry.fetch($0) } }
    #expect(await registry.calls == [root.digest])
}
