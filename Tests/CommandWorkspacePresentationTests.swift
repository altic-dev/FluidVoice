import Foundation

@main enum CommandWorkspacePresentationTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func main() {
        self.draftsBelongToTheirSessions()
        self.nilAndRemovedSessionsAreEmpty()
        self.rapidSessionTurnoverRetainsOnlyExistingDrafts()
        self.draftsAreIndependentValues()
        self.historyRespondsToWidthAndPreference()
        print("Command workspace presentation: \(self.checks) checks passed")
    }

    static func draftsBelongToTheirSessions() {
        var drafts = CommandSessionDrafts()
        drafts.set("Explain this file", for: "first")
        drafts.set("Check my storage", for: "second")
        self.check(drafts.text(for: "first") == "Explain this file", "Returning to the first session restores its unsent text")
        self.check(drafts.text(for: "second") == "Check my storage", "The second session keeps its own unsent text")
        self.check(drafts.text(for: "third").isEmpty, "A newly selected session starts without another session's text")
        drafts.set("", for: "first")
        self.check(drafts.text(for: "first").isEmpty, "Submitting or clearing removes only that session's draft")
        self.check(drafts.text(for: "second") == "Check my storage", "Clearing another session preserves this draft")
        drafts.set("line one\n  line two  ", for: "second")
        self.check(drafts.text(for: "second") == "line one\n  line two  ", "Draft storage preserves formatting and trailing whitespace for editing")
        drafts.set("   ", for: "first")
        self.check(drafts.text(for: "first") == "   ", "Draft storage does not trim or submit whitespace on its own")
    }

    static func nilAndRemovedSessionsAreEmpty() {
        var drafts = CommandSessionDrafts()
        drafts.set("orphan text", for: nil)
        self.check(drafts.text(for: nil).isEmpty, "Without a selected session, text is not assigned to any other session")
        drafts.set("keep", for: "kept")
        drafts.set("delete", for: "removed")
        drafts.retain(sessionIDs: ["kept", "new", "kept"])
        self.check(drafts.text(for: "kept") == "keep", "Retaining sessions preserves the existing live draft")
        self.check(drafts.text(for: "removed").isEmpty, "Deleted session IDs no longer retain unsent text")
        self.check(drafts.text(for: "new").isEmpty, "Retaining a new ID does not create or inherit a draft")
        drafts.retain(sessionIDs: ["kept", "new"])
        self.check(drafts.text(for: "kept") == "keep", "Repeated retention is stable")
        drafts.retain(sessionIDs: [])
        self.check(drafts.text(for: "kept").isEmpty && drafts.text(for: "removed").isEmpty, "An empty session list drops all drafts")
        drafts.retain(sessionIDs: ["removed"])
        self.check(drafts.text(for: "removed").isEmpty, "Reintroducing a removed ID does not resurrect deleted text")
    }

    static func rapidSessionTurnoverRetainsOnlyExistingDrafts() {
        var drafts = CommandSessionDrafts()
        var liveIDs: [String] = []
        for index in 0..<300 {
            let id = "session-\(index)"
            drafts.set("draft-\(index)", for: id)
            liveIDs.append(id)
            if liveIDs.count > 30 {
                let removedID = liveIDs.removeFirst()
                drafts.retain(sessionIDs: liveIDs)
                self.check(drafts.text(for: removedID).isEmpty, "Rapid create/delete cycles remove every discarded draft")
            } else {
                drafts.retain(sessionIDs: liveIDs)
            }
            self.check(drafts.text(for: id) == "draft-\(index)", "Pruning preserves the newly created session's draft")
        }
        for index in 0..<270 {
            self.check(drafts.text(for: "session-\(index)").isEmpty, "Discarded IDs stay absent after later retention passes")
        }
        for index in 270..<300 {
            self.check(drafts.text(for: "session-\(index)") == "draft-\(index)", "The bounded live set preserves each session's distinct text")
        }
        drafts.retain(sessionIDs: [])
        for id in liveIDs {
            self.check(drafts.text(for: id).isEmpty, "Deleting the remaining sessions clears all surviving drafts")
        }
    }

    static func draftsAreIndependentValues() {
        var firstWorkspace = CommandSessionDrafts()
        firstWorkspace.set("original", for: "same-session")
        var secondWorkspace = firstWorkspace
        secondWorkspace.set("other edit", for: "same-session")
        self.check(firstWorkspace.text(for: "same-session") == "original", "Editing a copied workspace cannot mutate the first workspace's draft")
        self.check(secondWorkspace.text(for: "same-session") == "other edit", "The copied workspace owns its new draft value")
        secondWorkspace.retain(sessionIDs: [])
        self.check(firstWorkspace.text(for: "same-session") == "original", "Pruning another value cannot mutate live drafts")
        let freshWorkspace = CommandSessionDrafts()
        self.check(freshWorkspace.text(for: "same-session").isEmpty, "A fresh workspace does not load drafts from shared persistence")
    }

    static func historyRespondsToWidthAndPreference() {
        let threshold = CommandWorkspaceLayout.dockedHistoryMinimumWidth
        self.check(!CommandWorkspaceLayout.showsDockedHistory(width: 0, preferred: true), "A zero-width workspace does not reserve sidebar space")
        self.check(!CommandWorkspaceLayout.showsDockedHistory(width: 640, preferred: true), "A narrow workspace leaves history undocked even with the default visible preference")
        self.check(!CommandWorkspaceLayout.showsDockedHistory(width: threshold - 0.5, preferred: true), "History stays undocked immediately below the width boundary")
        self.check(CommandWorkspaceLayout.showsDockedHistory(width: threshold, preferred: true), "History docks at the exact supported width")
        self.check(CommandWorkspaceLayout.showsDockedHistory(width: threshold + 0.5, preferred: true), "History docks immediately above the width boundary")
        self.check(CommandWorkspaceLayout.showsDockedHistory(width: 1440, preferred: true), "A wide workspace shows history with the default visible preference")
        for width: CGFloat in [0, 640, threshold, 1440] {
            self.check(!CommandWorkspaceLayout.showsDockedHistory(width: width, preferred: false), "Explicitly hiding history is honored at every width")
        }
        self.check(CommandWorkspaceLayout.showsDockedHistory(width: threshold, preferred: true), "A previous hidden-width query does not change future visibility")
        self.check(CommandWorkspaceLayout.sidebarWidth > 0 && CommandWorkspaceLayout.sidebarWidth < threshold, "The docked sidebar leaves positive width for the conversation")
        self.check(CommandWorkspaceLayout.conversationMaximumWidth > 0, "The conversation has a finite readable width limit")
    }
}
