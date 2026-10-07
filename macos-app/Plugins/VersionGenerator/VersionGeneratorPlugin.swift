import Foundation
import PackagePlugin

/// Build tool plugin that bakes the project version into the app at build
/// time. It runs scripts/generate_version.sh (the same generator the
/// firmware uses), which reads the committed `version.txt` at the project
/// root — line 1 is the version, line 2 the build number — and writes
/// ObsStatusVersion.swift into the plugin output directory. The generator
/// falls back to 1.0.0 / build 1 when the file is missing or malformed
/// (e.g. in CI), so this target keeps building either way.
@main
struct VersionGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let packageURL = URL(fileURLWithPath: context.package.directory.string)
        let projectRoot = packageURL.deletingLastPathComponent()
        let scriptURL = projectRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("generate_version.sh")
        let versionFile = projectRoot.appendingPathComponent("version.txt")
        let outputURL = URL(fileURLWithPath: context.pluginWorkDirectory.string)
            .appendingPathComponent("ObsStatusVersion.swift")

        var inputFiles: [Path] = [Path(scriptURL.path)]
        if FileManager.default.fileExists(atPath: versionFile.path) {
            inputFiles.append(Path(versionFile.path))
        }
        let output = Path(outputURL.path)

        return [
            Command.buildCommand(
                displayName: "Generating ObsStatusVersion.swift",
                executable: Path("/bin/sh"),
                arguments: [scriptURL.path, "swift", outputURL.path],
                inputFiles: inputFiles,
                outputFiles: [output]
            )
        ]
    }
}
