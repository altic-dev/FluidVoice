import Foundation

let arguments = CommandLine.arguments
let scenarios: Set<String> = ["offer", "manual", "progress", "failure", "dismiss", "no-update"]
guard arguments.count == 3, let pid = Int32(arguments[1]), pid > 0,
      scenarios.contains(arguments[2])
else {
    FileHandle.standardError.write(Data("Usage: swift Tests/trigger_update_ui_simulation.swift <simulation-app-pid> offer|manual|progress|failure|dismiss|no-update\n".utf8))
    exit(64)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.FluidApp.debug.updateUI"),
    object: String(pid),
    userInfo: ["scenario": arguments[2]],
    deliverImmediately: true
)
