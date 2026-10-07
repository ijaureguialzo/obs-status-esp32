//
//  ObsStatusVersion.swift
//
//  App version and build number.
//
//  The values are read from the app bundle's Info.plist at runtime. A target
//  run script bakes them there from the git-ignored version.txt at the
//  project root (scripts/generate_version.sh) after the bundle is assembled
//  and before code signing, so no generated source file is ever needed in
//  the source tree. When the values are missing (ad-hoc builds) it falls
//  back to 1.0.0 / build 1.
//

import Foundation

/// Build-time version and build number for the macOS app.
enum ObsStatusVersion {
    static let version: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    static let build: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    /// "1.0.0 (1)"
    static var display: String { "\(version) (\(build))" }
}
