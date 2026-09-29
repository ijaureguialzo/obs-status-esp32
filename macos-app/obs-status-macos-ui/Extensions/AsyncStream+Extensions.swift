//
//  AsyncStream+Extensions.swift
//  Utility extensions for async streams in the ObsStatus application
//

import Foundation

extension AsyncStream {
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
