import Foundation

// TEMPORARY (Task 3): Task 4 replaces this file with the real field sets for every one-way
// frame. Each type declares only `type` for now so `Frame` can fix its cases and payload
// types once, in Task 3.

public struct ToolProgressFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct ToolUseSummaryFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct RateLimitEventFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct AuthStatusFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct PromptSuggestionFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct ConversationResetFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct TranscriptMirrorFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}
public struct CommandLifecycleFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type }
}

public typealias ToolProgressFrame = Lossless<ToolProgressFields>
public typealias ToolUseSummaryFrame = Lossless<ToolUseSummaryFields>
public typealias RateLimitEventFrame = Lossless<RateLimitEventFields>
public typealias AuthStatusFrame = Lossless<AuthStatusFields>
public typealias PromptSuggestionFrame = Lossless<PromptSuggestionFields>
public typealias ConversationResetFrame = Lossless<ConversationResetFields>
public typealias TranscriptMirrorFrame = Lossless<TranscriptMirrorFields>
public typealias CommandLifecycleFrame = Lossless<CommandLifecycleFields>
