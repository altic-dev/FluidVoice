import Foundation

// `fv-serve` ships inside FluidVoice.app/Contents/Helpers. It answers one question and exits:
// no server, no model, no audio. The switch that allows it lives in the app's own preferences.

/// Where this program really is, asked of the loader. Not `argv[0]`, which is just "fv-serve" when
/// it is found through PATH, and not `Bundle.main`, which an environment variable can redirect:
/// either would let the caller choose which app's switch is read.
func realExecutableURL() -> URL {
    var size = UInt32(0)
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return URL(fileURLWithPath: "/") }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

let executable = realExecutableURL()

/// The bundle identifier of the app this copy shipped in, so Debug and release builds each read their own switch.
func enclosingAppBundleIdentifier() -> String {
    let infoPlist = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist", isDirectory: false)
    if let info = NSDictionary(contentsOf: infoPlist), let identifier = info["CFBundleIdentifier"] as? String {
        return identifier
    }
    return FluidServeMeetings.releaseBundleIdentifier
}

let bundleIdentifier = enclosingAppBundleIdentifier()
let result = FluidServeCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    root: FluidServeMeetings.defaultRoot(),
    accessEnabled: FluidServeMeetings.isAccessEnabled(bundleIdentifier: bundleIdentifier),
    toolPath: executable.path,
    customPrompt: FluidServeMeetings.customSummaryPrompt(bundleIdentifier: bundleIdentifier)
)
let stream = result.exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError
stream.write(Data((result.output + "\n").utf8))
exit(result.exitCode)
