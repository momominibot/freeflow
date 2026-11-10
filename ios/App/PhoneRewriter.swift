import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rewrites ("make it clearer", "friendlier", "shorter"...) done by Apple's on-device language model, so the text never leaves
/// the iPhone. It needs iOS 26 and a phone that supports Apple Intelligence; on any other phone the rest of Polish (spelling,
/// grammar, word swaps) still works and this explains why rewrites are off.
enum PhoneRewriter {
    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var isReady: Bool { self == .ready }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This iPhone cannot run Apple Intelligence, so rewriting is off. Spelling, grammar and word swaps still work.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Turn on Apple Intelligence in the Settings app to rewrite text. Spelling, grammar and word swaps work without it.")
                case .modelNotReady:
                    return .unavailable("Apple Intelligence is still getting ready on this iPhone. Try again in a few minutes.")
                @unknown default:
                    return .unavailable("Apple Intelligence is not available right now.")
                }
            }
        }
        #endif
        return .unavailable("Rewriting needs iOS 26 or later with Apple Intelligence. Spelling, grammar and word swaps work on this iPhone.")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The sentence shown when a rewrite was thrown away because it broke something it must not break.
    static let refused = "That rewrite changed something it should not have (a number, one of your words or the language), so it was thrown away. Try again."

    static func rewrite(_ text: String, mode: RewriteMode, terms: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard availability.isReady else {
                if case .unavailable(let why) = availability { throw Failure(message: why) }
                throw Failure(message: "Rewriting is not available.")
            }
            let session = LanguageModelSession(instructions: RewritePrompt.system)
            let options = GenerationOptions(temperature: mode == .fix ? 0.1 : (mode == .rephrase ? 0.7 : 0.3))
            do {
                let response = try await session.respond(to: RewritePrompt.user(text, mode: mode, terms: terms), options: options)
                let out = RewriteGuard.tidy(response.content)
                guard RewriteGuard.looksLikeRewrite(original: text, rewritten: out, mode: mode, protectedTerms: terms) else {
                    throw Failure(message: refused)
                }
                return out
            } catch let failure as Failure {
                throw failure
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    throw Failure(message: "That is too long for the on-device model. Rewrite a few paragraphs at a time.")
                case .guardrailViolation:
                    throw Failure(message: "Apple's on-device model declined to rewrite that text.")
                case .unsupportedLanguageOrLocale:
                    throw Failure(message: "Apple's on-device model does not support this language yet. Spelling and grammar checks still work for English.")
                default:
                    throw Failure(message: "The on-device model could not rewrite that. Try again.")
                }
            }
        }
        #endif
        throw Failure(message: "Rewriting needs iOS 26 or later with Apple Intelligence.")
    }
}
