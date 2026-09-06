import Foundation
import ContainerizationOCI
import Testing
@testable import Studio

private let digest = String(repeating: "a", count: 64)

@Test func defaultStackUsesStudioDistribution() {
    #expect(defaultOCIReference == "oci://ghcr.io/chatbotkit/platform-studio:latest")
}

@Test func imageLockAcceptsQuotedReferencesAndCRLF() throws {
    let yaml = "services:\r\n  redis:\r\n    image: 'redis@sha256:\(digest)'\r\n"
    #expect(try OCIComposeLoader.parseImageLock(yaml)["redis"] == "redis@sha256:\(digest)")
}

@Test func imageLockRejectsDuplicateImageKeysAndServicesBlocks() {
    let service = "  redis:\n    image: redis@sha256:\(digest)\n"
    #expect(throws: AppRuntimeError.self) { try OCIComposeLoader.parseImageLock("services:\n" + service + "    image: redis@sha256:\(digest)\n") }
    #expect(throws: AppRuntimeError.self) { try OCIComposeLoader.parseImageLock("services:\n" + service + "services:\n" + service) }
}

@Test func ociLayersRequireMatchingSizeAndSHA256() throws {
    let data = Data("hello".utf8)
    let hash = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    try OCIComposeLoader.verify(data, descriptor: Descriptor(mediaType: "text/yaml", digest: hash, size: 5))
    #expect(throws: AppRuntimeError.self) {
        try OCIComposeLoader.verify(data, descriptor: Descriptor(mediaType: "text/yaml", digest: hash, size: 6))
    }
    #expect(throws: AppRuntimeError.self) {
        try OCIComposeLoader.verify(Data("Hello".utf8), descriptor: Descriptor(mediaType: "text/yaml", digest: hash, size: 5))
    }
}

@Test(arguments: ["platform-studio", "platform-community"])
func imageLockParsesPinnedServices(_ distribution: String) throws {
    let yaml = "services:\n  redis:\n    image: docker.io/library/redis@sha256:\(digest)\n  platform:\n    image: ghcr.io/chatbotkit/\(distribution)-app@sha256:\(digest)\n"
    let images = try OCIComposeLoader.parseImageLock(yaml)
    #expect(images.count == 2)
    #expect(images["redis"] == "docker.io/library/redis@sha256:\(digest)")
    #expect(images["platform"] == "ghcr.io/chatbotkit/\(distribution)-app@sha256:\(digest)")
}

@Test func imageLockRejectsMutableTags() {
    #expect(throws: AppRuntimeError.self) {
        try OCIComposeLoader.parseImageLock("services:\n  redis:\n    image: redis:latest\n")
    }
}

@Test(arguments: ["", "abc", String(repeating: "z", count: 64), String(repeating: "a", count: 63)])
func imageLockRejectsMalformedDigests(_ hash: String) {
    #expect(throws: AppRuntimeError.self) {
        try OCIComposeLoader.parseImageLock("services:\n  redis:\n    image: redis@sha256:\(hash)\n")
    }
}

@Test func imageLockRejectsAmbiguousDuplicateServices() {
    let yaml = "services:\n  redis:\n    image: redis@sha256:\(digest)\n  redis:\n    image: redis@sha256:\(String(repeating: "b", count: 64))\n"
    #expect(throws: AppRuntimeError.self) { try OCIComposeLoader.parseImageLock(yaml) }
}

@Test func imageLockDoesNotTreatOtherSectionsAsServices() throws {
    let yaml = "services:\n  redis:\n    image: redis@sha256:\(digest)\nx-ignored:\n  platform:\n    image: attacker.example/app@sha256:\(digest)\n"
    let images = try OCIComposeLoader.parseImageLock(yaml)
    #expect(images["platform"] == nil)
}
