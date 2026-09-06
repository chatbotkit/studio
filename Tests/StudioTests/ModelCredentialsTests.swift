import Foundation
import Testing
@testable import Studio

@Test func modelProviderCatalogueMatchesPlatformCredentialGates() {
    #expect(ModelCredentialCatalog.providers.map(\.id) == [
        "openai", "openrouter", "vercel", "vertex", "bedrock", "cloudflare",
        "perplexity", "mistral", "groq", "deepseek"
    ])
    #expect(ModelCredentialCatalog.managedKeys == [
        "OPENAI_API_KEY", "OPENAI_MODELS_API_KEY", "OPENROUTER_MODELS_API_KEY",
        "VERCEL_MODELS_API_KEY", "VERTEX_MODELS_API_KEY", "BEDROCK_MODELS_API_KEY",
        "CLOUDFLARE_MODELS_ACCOUNT_ID", "CLOUDFLARE_MODELS_API_KEY",
        "PERPLEXITY_MODELS_API_KEY", "MISTRAL_MODELS_API_KEY",
        "GROQ_MODELS_API_KEY", "DEEPSEEK_MODELS_API_KEY"
    ])
}

@Test func configuredProviderRequiresEveryFieldAndAcceptsOpenAIAlias() throws {
    let openAI = try #require(ModelCredentialCatalog.providers.first { $0.id == "openai" })
    let cloudflare = try #require(ModelCredentialCatalog.providers.first { $0.id == "cloudflare" })
    #expect(openAI.isConfigured(in: ["OPENAI_MODELS_API_KEY"]))
    #expect(!cloudflare.isConfigured(in: ["CLOUDFLARE_MODELS_API_KEY"]))
    #expect(cloudflare.isConfigured(in: ["CLOUDFLARE_MODELS_API_KEY", "CLOUDFLARE_MODELS_ACCOUNT_ID"]))
}

@Test func replacingOpenAIKeyClearsTheHigherPrecedenceAlias() throws {
    let openAI = try #require(ModelCredentialCatalog.providers.first { $0.id == "openai" })
    let changes = try ModelCredentialCatalog.changes(
        for: openAI,
        drafts: ["OPENAI_API_KEY": "  sk-new  "],
        configuredKeys: ["OPENAI_MODELS_API_KEY"]
    )
    #expect(changes == [
        .init(key: "OPENAI_MODELS_API_KEY", value: nil),
        .init(key: "OPENAI_API_KEY", value: "sk-new")
    ])
}

@Test func credentialChangesPreserveConfiguredFieldsAndRejectUnsafeValues() throws {
    let cloudflare = try #require(ModelCredentialCatalog.providers.first { $0.id == "cloudflare" })
    let changes = try ModelCredentialCatalog.changes(
        for: cloudflare,
        drafts: ["CLOUDFLARE_MODELS_API_KEY": "token-new"],
        configuredKeys: ["CLOUDFLARE_MODELS_ACCOUNT_ID"]
    )
    #expect(changes == [.init(key: "CLOUDFLARE_MODELS_API_KEY", value: "token-new")])
    #expect(throws: AppRuntimeError.self) {
        try ModelCredentialCatalog.changes(
            for: cloudflare,
            drafts: [
                "CLOUDFLARE_MODELS_ACCOUNT_ID": "account",
                "CLOUDFLARE_MODELS_API_KEY": "first\nsecond"
            ],
            configuredKeys: []
        )
    }
}

@Test func removingAProviderClearsEveryRecognizedKey() throws {
    let openAI = try #require(ModelCredentialCatalog.providers.first { $0.id == "openai" })
    #expect(ModelCredentialCatalog.removals(for: openAI) == [
        .init(key: "OPENAI_API_KEY", value: nil),
        .init(key: "OPENAI_MODELS_API_KEY", value: nil)
    ])
    let encoded = try JSONEncoder().encode(ModelCredentialCatalog.removals(for: openAI))
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    #expect(json.allSatisfy { $0.keys.contains("value") && $0["value"] is NSNull })
}
