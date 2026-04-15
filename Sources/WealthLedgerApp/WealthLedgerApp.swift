#if canImport(SwiftUI)
// Placeholder for WealthLedgerApp - to be implemented
import Foundation
@main struct WealthLedgerApp { static func main() {} }
#else
// Stub entry point for non-macOS platforms (Linux CI)
import Foundation
@main struct WealthLedgerApp { static func main() { fatalError("Requires macOS") } }
#endif
