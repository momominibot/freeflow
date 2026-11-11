import Foundation

/// The three ways to get Purrscribe, as the Account tab shows them:
///   1. Free, on your own Mac with your own local models (what this app is; LocalModel.swift sets the models up).
///   2. A monthly cloud plan for people who would rather not run models (paid through a Stripe Checkout link, payments go to Ranklore).
///   3. Build it yourself from the source on GitHub.
enum Plans {
    /// Where the source lives. The repository has to be public (and carry a licence) before this link works for anyone else.
    static let sourceURL = URL(string: "https://github.com/momominibot/freeflow")!

    /// The checkout link of the cloud plan, from the Info.plist key PurrscribeCloudCheckoutURL. It is not in the repo: a build opts in with
    /// PURRSCRIBE_CHECKOUT_URL (build.sh), and only a build whose cloud service exists should do that. Without it the plan says "Coming soon".
    static var checkoutURL: URL? {
        checkoutURL(from: Bundle.main.object(forInfoDictionaryKey: "PurrscribeCloudCheckoutURL") as? String)
    }

    /// Only a plain https link with a host counts; anything else (http, javascript:, empty) means there is no checkout.
    static func checkoutURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
