import Foundation

/// Why Xbox refuses an account, read from the `XErr` code of its 401 answer, and what the player can do about it.
///
/// The game only says "Initialization Failed" (E:0-c2-4) or asks to sign in. For these refusals signing in again changes
/// nothing, and before 1.0.4 that was all MetalHorizon offered, so a player could sign in again and again: the account
/// itself needs something, on Microsoft's or Xbox's own pages. The codes are Xbox's (the list Xbox sign-in libraries
/// such as xal and prismarine-auth keep). xodus-service writes Xbox's answer to its log ("Xbox answered 401 … XErr …"),
/// and its `--check` prints it too.
struct XboxRefusal: Equatable {
    let code: UInt64
    let id: String
    let title: String
    let detail: String
    let button: String
    let url: URL

    static let all: [XboxRefusal] = [
        XboxRefusal(code: 2148916233, id: "xbox-no-profile", title: "This Microsoft account has no Xbox profile yet",
                    detail: "Xbox knows no profile (gamertag) for this account, so it gives the game no sign-in. Sign in once on xbox.com with the same account and create your profile, then use Sign In Again in MetalHorizon.",
                    button: "Create Xbox Profile", url: URL(string: "https://www.xbox.com/live")!),
        XboxRefusal(code: 2148916234, id: "xbox-terms", title: "Xbox's terms of use are not accepted on this account",
                    detail: "Xbox waits for the account to accept its current terms. Sign in on xbox.com with the same account and accept them, then use Sign In Again in MetalHorizon.",
                    button: "Open xbox.com", url: URL(string: "https://www.xbox.com/")!),
        XboxRefusal(code: 2148916235, id: "xbox-region", title: "Xbox is not available in this account's country or region",
                    detail: "Xbox refuses sign-ins from the country or region set on this Microsoft account. Check the account's country on Microsoft's page; a VPN placing the Mac elsewhere can cause it too.",
                    button: "Open My Microsoft Account", url: URL(string: "https://account.microsoft.com/profile")!),
        XboxRefusal(code: 2148916236, id: "xbox-age-proof", title: "Xbox needs proof of age for this account",
                    detail: "Xbox asks this account to confirm the owner's age before it can sign in (required in some countries). Do it on Microsoft's page, then use Sign In Again in MetalHorizon.",
                    button: "Open My Microsoft Account", url: URL(string: "https://account.microsoft.com/profile")!),
        XboxRefusal(code: 2148916237, id: "xbox-time-limit", title: "This account reached its play-time limit",
                    detail: "The family settings of this account allow no more play time today. An adult of the family can change it on Microsoft's family page.",
                    button: "Open Microsoft Family", url: URL(string: "https://account.microsoft.com/family")!),
        XboxRefusal(code: 2148916238, id: "xbox-child-account", title: "A child account must be added to a Microsoft family",
                    detail: "The account belongs to someone under 18, and Xbox lets it sign in only once an adult adds it to a Microsoft family and allows online play.",
                    button: "Open Microsoft Family", url: URL(string: "https://account.microsoft.com/family")!),
        XboxRefusal(code: 2148916229, id: "xbox-guardian", title: "The family settings do not allow online play",
                    detail: "The account is restricted and its guardian has not allowed online play. An adult of the family can change it on Microsoft's family page.",
                    button: "Open Microsoft Family", url: URL(string: "https://account.microsoft.com/family")!),
        XboxRefusal(code: 2148916227, id: "xbox-enforcement", title: "Xbox has suspended this account",
                    detail: "Xbox refuses this account for an enforcement action; nothing on this Mac can change that. Xbox's enforcement page says why and how to appeal.",
                    button: "Open Xbox Enforcement", url: URL(string: "https://enforcement.xbox.com")!),
    ]

    /// The refusal named by the first `XErr` code in `text` (a log line, the check's output), when it is a known one.
    static func from(_ text: String) -> XboxRefusal? {
        guard let regex = try? NSRegularExpression(pattern: #""?XErr"?\s*[:=]?\s*(\d{9,11})"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let code = UInt64(text[range]) else { return nil }
        return all.first { $0.code == code }
    }

    /// The same refusals for Diagnostics: a run whose service log shows one says what to do, not just E:0-c2-4.
    static var knownIssues: [KnownIssue] {
        all.map { refusal in
            KnownIssue(id: refusal.id, title: refusal.title,
                       patterns: [#""?XErr"?\s*[:=]?\s*"# + String(refusal.code)],
                       explanation: refusal.detail + " The game then says Initialization Failed (E:0-c2-4) or asks to sign in.",
                       fix: "\(refusal.button): \(refusal.url.absoluteString), then Sign In Again (Settings › General).",
                       edition: .xbox)
        }
    }
}
