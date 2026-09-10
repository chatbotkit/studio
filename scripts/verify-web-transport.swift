import Foundation

// Compare the entire policy so global bypasses, non-local subdomain exceptions,
// and accidental exceptions for remote sites fail packaging verification.
let expected: NSDictionary = [
    "NSExceptionDomains": [
        "localhost": ["NSExceptionAllowsInsecureHTTPLoads": true, "NSIncludesSubdomains": true],
    ],
]

func isValid(_ policy: Any?) -> Bool {
    guard let policy = policy as? NSDictionary else { return false }
    return policy.isEqual(to: expected as! [AnyHashable: Any])
}

if CommandLine.arguments.dropFirst().first == "--self-test" {
    precondition(isValid(expected))
    precondition(!isValid(nil))
    precondition(!isValid([:]))
    precondition(!isValid(["NSAllowsArbitraryLoads": true]))
    for key in ["NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking"] {
        let policy = expected.mutableCopy() as! NSMutableDictionary
        policy[key] = true
        precondition(!isValid(policy))
    }
    for host in ["localhost"] {
        var domains = expected["NSExceptionDomains"] as! [String: [String: Bool]]
        domains.removeValue(forKey: host)
        precondition(!isValid(["NSExceptionDomains": domains]))
        domains[host] = ["NSExceptionAllowsInsecureHTTPLoads": false]
        precondition(!isValid(["NSExceptionDomains": domains]))
        domains[host] = ["NSExceptionAllowsInsecureHTTPLoads": true]
        precondition(!isValid(["NSExceptionDomains": domains]))
    }
    var domains = expected["NSExceptionDomains"] as! [String: [String: Bool]]
    domains["example.com"] = ["NSExceptionAllowsInsecureHTTPLoads": true]
    precondition(!isValid(["NSExceptionDomains": domains]))
    print("Web transport policy regression tests passed.")
} else {
    guard CommandLine.arguments.count == 2 else {
        fatalError("Usage: swift verify-web-transport.swift /path/to/Info.plist | --self-test")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    guard isValid(plist?["NSAppTransportSecurity"]) else {
        fputs("Invalid web transport policy: expected only localhost and its subdomains.\n", stderr)
        exit(1)
    }
    print("Verified: HTTP exceptions limited to localhost and its subdomains.")
}
