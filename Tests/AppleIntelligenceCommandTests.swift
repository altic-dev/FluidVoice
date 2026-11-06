import Foundation

@main
struct AppleIntelligenceCommandTests {
    static func main() {
        let call = AppleIntelligenceCall(id: "c1", command: "ls", workingDirectory: nil, purpose: "checking")
        let turns = AppleIntelligenceTurn.turns([
            (.user, "list files", nil), (.assistant, "thinking aloud", call), (.tool, "a.txt", nil), (.assistant, "done", nil),
        ])
        self.check(turns == [.user("list files"), .call(call), .output(id: "c1", text: "a.txt"), .text("done")], "history maps in order with the call id on its output")

        let long = "{\n  \"command\" : \"cat /tmp/a.txt\",\n  \"exitCode\" : 0,\n  \"output\" : \"\(String(repeating: "x", count: 5000))\"\n}"
        guard case let .output(_, capped) = AppleIntelligenceTurn.output(id: "c1", text: long).capped,
              let json = try? JSONSerialization.jsonObject(with: Data(capped.utf8)) as? [String: Any] else { return self.check(false, "capped output stays valid JSON") }
        self.check((json["output"] as? String)?.count ?? 9999 < 1600 && json["exitCode"] as? Int == 0, "output field is capped, other fields kept")
        self.check(!capped.contains("\\/") && capped.contains("/tmp/a.txt"), "truncated output keeps unescaped slashes")
        let short = "{\n  \"command\" : \"cat /tmp/a.txt\",\n  \"exitCode\" : 0,\n  \"output\" : \"ok\"\n}"
        self.check(AppleIntelligenceTurn.output(id: "c1", text: short).capped == .output(id: "c1", text: short), "short output is untouched")

        let history: [AppleIntelligenceTurn] = [.user("a"), .call(call), .output(id: "c1", text: "o"), .text("done"), .user("b"), .call(call)]
        let trimmed = AppleIntelligenceTurn.droppingOldestRequest(history)
        self.check(trimmed == [.user("b"), .call(call)], "trimming drops the whole oldest request")
        self.check(AppleIntelligenceTurn.droppingOldestRequest(trimmed).isEmpty, "the current request is never dropped")
        print("All Apple Intelligence command tests passed")
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }
}
