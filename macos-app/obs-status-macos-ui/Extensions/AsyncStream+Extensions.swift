//
//  AsyncStream+Extensions.swift
//  Utility extensions for async streams in the ObsStatus application
//

import Foundation

// The AsyncStream build closure is @Sendable, so the element type must be
// Sendable for the values to cross into it safely.
extension AsyncStream where Element: Sendable {
    /// Convert an AsyncStream to an array (useful for testing)
    static func fromArray(_ items: [Element]) -> AsyncStream<Element> {
        AsyncStream { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }
}
