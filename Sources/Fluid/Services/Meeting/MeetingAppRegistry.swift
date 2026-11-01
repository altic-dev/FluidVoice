import Foundation

/// Detection tier for a registry app. Tier 1 (native) is default-on; Tier 2 (browser) is an
/// opt-in sub-toggle because it reads the frontmost tab's URL.
nonisolated enum MeetingDetectionTier: Sendable, Equatable {
    case nativeTier1
    case browserTier2
}

/// Static, data-driven table of the apps the auto-detector watches. Every ambiguity resolves to
/// "not in the registry" — Slack, Discord, FaceTime and generic browsers-without-a-known-meeting-URL
/// are deliberately absent (see Phase A plan: dropped from v1).
nonisolated enum MeetingAppRegistry {
    /// Bundle identifiers for native meeting apps (Tier 1). Includes legacy Teams alongside the
    /// current "new Teams" bundle since both ship in the wild.
    static let nativeBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
    ]

    /// Bundle identifiers for browsers eligible for Tier 2 URL reading. Google Meet's "app" is a
    /// Chrome/Edge PWA, not a separate bundle — it is matched via `pwaBundlePrefixes` instead.
    static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    /// PWA windows report a per-app bundle ID with one of these prefixes. Firefox has no PWA
    /// mechanism comparable to this and is excluded from the registry entirely (its AX tree must
    /// be force-enabled by the user, so it fails closed anyway).
    static let pwaBundlePrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.microsoft.edgemac.app.",
    ]

    /// A browser web app such as Google Meet's runs inside its browser, which is the process that
    /// actually holds the microphone. Nil for anything that is not such a web app.
    static func parentBrowser(ofWebApp bundleIdentifier: String) -> String? {
        guard let prefix = self.pwaBundlePrefixes.first(where: { bundleIdentifier.hasPrefix($0) }) else { return nil }
        return String(prefix.dropLast(".app.".count))
    }

    static func tier(forBundleIdentifier bundleIdentifier: String) -> MeetingDetectionTier? {
        if self.nativeBundleIdentifiers.contains(bundleIdentifier) {
            return .nativeTier1
        }
        if self.browserBundleIdentifiers.contains(bundleIdentifier) {
            return .browserTier2
        }
        if self.pwaBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return .browserTier2
        }
        return nil
    }

    static func isNativeMeetingApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .nativeTier1
    }

    static func isBrowserApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .browserTier2
    }

    // MARK: - Source picker order

    /// Call apps people record by hand that detection does not cover. They only shape the order
    /// of the source pickers; nothing here is detected or prompted for.
    static let otherCallAppBundleIdentifiers: [String] = [
        "com.apple.FaceTime",
        "com.apple.iChat",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
        "com.skype.skype",
    ]

    private static let pickerCallAppOrder: [String] = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
    ]

    private static let pickerBrowserOrder: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.duckduckgo.macos.browser",
    ]

    static var commonPickerBundleIdentifiers: [String] {
        self.pickerBrowserOrder + self.pickerCallAppOrder + self.otherCallAppBundleIdentifiers
    }

    /// Browsers and meeting apps first, then web apps and personal call apps. This ranking
    /// changes only manual source pickers; automatic detection keeps its separate registry.
    static func pickerRank(forBundleIdentifier bundleIdentifier: String) -> Int? {
        if let index = self.pickerBrowserOrder.firstIndex(of: bundleIdentifier) { return index }
        let nativeOffset = self.pickerBrowserOrder.count
        if let index = self.pickerCallAppOrder.firstIndex(of: bundleIdentifier) { return nativeOffset + index }
        let webAppOffset = nativeOffset + self.pickerCallAppOrder.count
        if self.pwaBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) { return webAppOffset }
        if let index = self.otherCallAppBundleIdentifiers.firstIndex(of: bundleIdentifier) { return webAppOffset + 1 + index }
        return nil
    }

    /// Splits a source list for a picker: the usual meeting sources first in a fixed order, then
    /// everything else by name with background items (menu bar helpers, agents) at the very end.
    static func pickerSections<Item>(
        _ items: [Item],
        bundleIdentifier: (Item) -> String,
        name: (Item) -> String,
        isBackgroundItem: (Item) -> Bool
    ) -> (usual: [Item], others: [Item]) {
        func byName(_ lhs: Item, _ rhs: Item) -> Bool {
            name(lhs).localizedCaseInsensitiveCompare(name(rhs)) == .orderedAscending
        }
        let ranked = items.compactMap { item in self.pickerRank(forBundleIdentifier: bundleIdentifier(item)).map { (item, $0) } }
        let usual = ranked.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : byName($0.0, $1.0) }.map(\.0)
        let rest = items.filter { self.pickerRank(forBundleIdentifier: bundleIdentifier($0)) == nil }
        let others = rest.filter { !isBackgroundItem($0) }.sorted(by: byName) + rest.filter(isBackgroundItem).sorted(by: byName)
        return (usual, others)
    }

    private static let zoomMeetingTitles: Set<String> = [
        // en
        "Zoom", "Zoom Meeting", "Zoom Webinar",
        // es
        "Reunión de Zoom", "Seminario web de Zoom",
        // fr
        "Réunion Zoom", "Webinaire Zoom",
        // de
        "Zoom-Meeting", "Zoom-Webinar",
        // pt
        "Reunião do Zoom", "Webinar do Zoom",
        // ja
        "Zoom ミーティング", "Zoom ウェビナー",
    ]

    private static let zoomNonMeetingWindowTitles: Set<String> = [
        "", "Zoom Workplace", "Zoom Client Healthcheck",
    ]

    static func isZoomMeetingWindowTitle(_ title: String) -> Bool {
        guard !self.zoomNonMeetingWindowTitles.contains(title) else { return false }
        return self.zoomMeetingTitles.contains(title)
    }
}

/// Pure hostname+path matching for Tier 2 in-call URLs. Homepage/landing/post-call URLs never
/// match — a parked meeting tab must not, by itself, ever produce a prompt.
nonisolated enum MeetingInCallURLMatcher {
    static func isInCallURL(host: String, path: String) -> Bool {
        let host = host.lowercased()
        switch true {
        case host == "meet.google.com":
            return self.matchesGoogleMeetPath(path)
        case host.hasSuffix(".zoom.us") || host == "zoom.us":
            return self.matchesZoomPath(path)
        case host == "teams.microsoft.com" || host == "teams.live.com":
            return self.matchesTeamsPath(path)
        case host == "whereby.com" || host == "www.whereby.com":
            return self.matchesRoomPath(path, excluding: Self.wherebyReservedPaths)
        case host == "meet.jit.si":
            return self.matchesRoomPath(path, excluding: Self.jitsiReservedPaths)
        default:
            return false
        }
    }

    /// `/xxx-yyyy-zzz` or `/meet/xxx-yyyy-zzz` — the same lowercase-letter room code.
    private static func matchesGoogleMeetPath(_ path: String) -> Bool {
        var segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if segment.hasPrefix("meet/") { segment.removeFirst("meet/".count) }
        let parts = segment.split(separator: "-")
        guard parts.count == 3 else { return false }
        let lengths = parts.map(\.count)
        guard lengths == [3, 4, 3] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isLowercaseASCIILetter) }
    }

    private static func matchesZoomPath(_ path: String) -> Bool {
        path.hasPrefix("/j/") || path.hasPrefix("/wc/")
    }

    private static func matchesTeamsPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("meetup-join") || lowered.contains("prejoin") || lowered.contains("pre-join")
    }

    private static let wherebyReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "download", "about"]
    private static let jitsiReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "static"]

    private static func matchesRoomPath(_ path: String, excluding reserved: Set<String>) -> Bool {
        let segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !segment.isEmpty, !segment.contains("/") else { return false }
        return !reserved.contains(segment)
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool {
        ("a"..."z").contains(self)
    }
}
