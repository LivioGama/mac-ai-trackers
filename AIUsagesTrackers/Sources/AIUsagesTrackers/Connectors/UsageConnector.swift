import Foundation

public protocol UsageConnector: Sendable {
    var vendor: Vendor { get }
    func fetchUsages() async throws -> [VendorUsageEntry]
    func resolveActiveAccount() -> AccountEmail?
}

public extension UsageConnector {
    nonisolated func knownAccounts() -> [AccountEmail] {
        resolveActiveAccount().map { [$0] } ?? []
    }
}
