import Foundation
import SwiftUI

struct ModelCredentialField: Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    let prompt: String
    let secret: Bool
    let aliases: [String]

    var id: String { key }
    var recognizedKeys: [String] { [key] + aliases }
}

struct ModelProvider: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let fields: [ModelCredentialField]

    func isConfigured(in keys: Set<String>) -> Bool {
        fields.allSatisfy { field in
            field.recognizedKeys.contains(where: keys.contains)
        }
    }
}

struct ModelCredentialChange: Encodable, Equatable, Sendable {
    let key: String
    let value: String?

    private enum CodingKeys: String, CodingKey { case key, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

enum ModelCredentialCatalog {
    static let providers: [ModelProvider] = [
        .init(
            id: "openai",
            name: "OpenAI",
            detail: "GPT, image, audio, realtime, and embedding models.",
            fields: [.init(
                key: "OPENAI_API_KEY",
                label: "API key",
                prompt: "sk-…",
                secret: true,
                aliases: ["OPENAI_MODELS_API_KEY"]
            )]
        ),
        .init(
            id: "openrouter",
            name: "OpenRouter",
            detail: "Models available through the OpenRouter gateway.",
            fields: [.init(key: "OPENROUTER_MODELS_API_KEY", label: "API key", prompt: "sk-or-…", secret: true, aliases: [])]
        ),
        .init(
            id: "vercel",
            name: "Vercel AI Gateway",
            detail: "Models available through Vercel AI Gateway.",
            fields: [.init(key: "VERCEL_MODELS_API_KEY", label: "API key", prompt: "AI Gateway key", secret: true, aliases: [])]
        ),
        .init(
            id: "vertex",
            name: "Google AI",
            detail: "Gemini models through Google’s OpenAI-compatible API.",
            fields: [.init(key: "VERTEX_MODELS_API_KEY", label: "API key", prompt: "Google AI API key", secret: true, aliases: [])]
        ),
        .init(
            id: "bedrock",
            name: "Amazon Bedrock",
            detail: "Models through the Bedrock OpenAI-compatible endpoint.",
            fields: [.init(key: "BEDROCK_MODELS_API_KEY", label: "API key", prompt: "Bedrock API key", secret: true, aliases: [])]
        ),
        .init(
            id: "cloudflare",
            name: "Cloudflare Workers AI",
            detail: "Workers AI models for a Cloudflare account.",
            fields: [
                .init(key: "CLOUDFLARE_MODELS_ACCOUNT_ID", label: "Account ID", prompt: "Cloudflare account ID", secret: false, aliases: []),
                .init(key: "CLOUDFLARE_MODELS_API_KEY", label: "API token", prompt: "Cloudflare API token", secret: true, aliases: [])
            ]
        ),
        .init(
            id: "perplexity",
            name: "Perplexity",
            detail: "Perplexity search and reasoning models.",
            fields: [.init(key: "PERPLEXITY_MODELS_API_KEY", label: "API key", prompt: "Perplexity API key", secret: true, aliases: [])]
        ),
        .init(
            id: "mistral",
            name: "Mistral AI",
            detail: "Mistral language models.",
            fields: [.init(key: "MISTRAL_MODELS_API_KEY", label: "API key", prompt: "Mistral API key", secret: true, aliases: [])]
        ),
        .init(
            id: "groq",
            name: "Groq",
            detail: "Language models served by Groq.",
            fields: [.init(key: "GROQ_MODELS_API_KEY", label: "API key", prompt: "Groq API key", secret: true, aliases: [])]
        ),
        .init(
            id: "deepseek",
            name: "DeepSeek",
            detail: "DeepSeek language and reasoning models.",
            fields: [.init(key: "DEEPSEEK_MODELS_API_KEY", label: "API key", prompt: "DeepSeek API key", secret: true, aliases: [])]
        )
    ]

    static let managedKeys = Set(providers.flatMap { provider in
        provider.fields.flatMap(\.recognizedKeys)
    })

    static func changes(
        for provider: ModelProvider,
        drafts: [String: String],
        configuredKeys: Set<String>
    ) throws -> [ModelCredentialChange] {
        var result: [ModelCredentialChange] = []
        for field in provider.fields {
            let value = (drafts[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                guard field.recognizedKeys.contains(where: configuredKeys.contains) else {
                    throw AppRuntimeError("Enter \(field.label.lowercased()) for \(provider.name).")
                }
                continue
            }
            guard value.utf8.count <= 16_384,
                  value.unicodeScalars.allSatisfy({ $0.value != 0 && $0.value != 10 && $0.value != 13 }) else {
                throw AppRuntimeError("\(field.label) is not a valid single-line value.")
            }
            result.append(contentsOf: field.aliases.map { ModelCredentialChange(key: $0, value: nil) })
            result.append(.init(key: field.key, value: value))
        }
        guard !result.isEmpty else {
            throw AppRuntimeError("Enter a new value before saving.")
        }
        return result
    }

    static func removals(for provider: ModelProvider) -> [ModelCredentialChange] {
        provider.fields.flatMap { field in
            field.recognizedKeys.map { ModelCredentialChange(key: $0, value: nil) }
        }
    }
}

struct ModelProvidersSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProviderID = ModelCredentialCatalog.providers[0].id
    @State private var drafts: [String: String] = [:]
    @State private var validationError: String?
    @State private var confirmingRemoval = false

    private var provider: ModelProvider {
        ModelCredentialCatalog.providers.first { $0.id == selectedProviderID }
            ?? ModelCredentialCatalog.providers[0]
    }

    private var isConfigured: Bool {
        provider.isConfigured(in: model.configuredModelCredentialKeys)
    }

    private var hasDraft: Bool {
        provider.fields.contains { !(drafts[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(ModelCredentialCatalog.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        isConfigured ? "Configured" : "Not configured",
                        systemImage: isConfigured ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(isConfigured ? .green : .secondary)
                }

                ForEach(provider.fields) { field in
                    LabeledContent(field.label) {
                        if field.secret {
                            SecureField(isConfigured ? "Enter a replacement" : field.prompt, text: draftBinding(for: field.key))
                                .textContentType(.password)
                        } else {
                            TextField(isConfigured ? "Enter a replacement" : field.prompt, text: draftBinding(for: field.key))
                        }
                    }
                }
            } header: {
                Text(provider.name)
            } footer: {
                Text(provider.detail + " Saved values stay in Studio’s private platform-data disk and are never displayed again.")
            }

            Section {
                HStack {
                    Button("Save Provider") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.info == nil || model.storageBusy || model.modelCredentialsBusy || !hasDraft)
                    if isConfigured {
                        Button("Remove…", role: .destructive) { confirmingRemoval = true }
                            .disabled(model.info == nil || model.storageBusy || model.modelCredentialsBusy)
                    }
                    Spacer()
                    if model.modelCredentialsBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Updating model provider credentials")
                    } else {
                        Button("Refresh") { model.inspectModelCredentials() }
                            .disabled(model.info == nil || model.storageBusy)
                    }
                }
            }

            if model.info == nil {
                Section {
                    Text("Model providers can be configured after Studio’s private platform has started.")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = validationError ?? model.modelCredentialsError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let notice = model.modelCredentialsNotice {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.info?.podID) { model.inspectModelCredentials() }
        .onChange(of: selectedProviderID) { _, _ in
            drafts.removeAll(keepingCapacity: true)
            validationError = nil
        }
        .confirmationDialog("Remove the saved credentials for \(provider.name)?", isPresented: $confirmingRemoval) {
            Button("Remove Credentials", role: .destructive) {
                drafts.removeAll(keepingCapacity: true)
                validationError = nil
                model.updateModelCredentials(ModelCredentialCatalog.removals(for: provider))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Models from this provider will no longer be available after the platform reloads.")
        }
    }

    private func draftBinding(for key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0; validationError = nil }
        )
    }

    private func save() {
        do {
            let changes = try ModelCredentialCatalog.changes(
                for: provider,
                drafts: drafts,
                configuredKeys: model.configuredModelCredentialKeys
            )
            drafts.removeAll(keepingCapacity: true)
            validationError = nil
            model.updateModelCredentials(changes)
        } catch {
            validationError = error.localizedDescription
        }
    }
}
