import Accelerate
import Foundation

/// Finds a recorded word inside a dictation by sliding each recording's encoder frames along
/// the dictation (subsequence dynamic time warping). The best stretch may start and end anywhere,
/// and its length may differ from the recording, so the word can be faster or slower in a sentence.
nonisolated enum DictionaryStampMatcher {
    // Distance = mean per-frame cosine distance along the matched path (0 identical, 1 unrelated).
    // Tuned 2026-10-20 on 2,007 checks (5 words x the user's last 500 dictations + test sentences):
    // real uses 0.03-0.20, deliberate sound-alikes 0.180 and 0.198, ordinary speech never below 0.268.
    // At these values: 40 of 43 real uses caught, 0 of 1,964 others swapped (a fixed 0.14 caught 32).

    /// Below this, the sound alone is enough to replace.
    static let sureDistance: Float = 0.16
    /// Between `sureDistance` and this, replace only if the words also look like the word
    /// (see `DictionaryAudioSpan.greyZoneMinimumResemblance`). At or above it, never replace.
    static let greyZoneLimit: Float = 0.175
    static let maximumQueryFrames = 1500

    struct Hit: Equatable, Sendable {
        let frames: Range<Int>
        let distance: Float
    }

    /// A dictation's frames, normalized once and shared by every dictionary word's search.
    struct Query: Sendable {
        let values: [Float]
        let count: Int
        let hiddenSize: Int
    }

    static func prepare(_ query: DictionaryMatchFrames) -> Query? {
        let m = query.count
        guard m > 0, m <= self.maximumQueryFrames, query.values.count == m * query.hiddenSize,
              query.values.allSatisfy(\.isFinite) else { return nil }
        return Query(values: self.normalizedRows(query), count: m, hiddenSize: query.hiddenSize)
    }

    /// Up to `limit` non-overlapping stretches of `query` closer than `greyZoneLimit` to any reference.
    static func hits(references: [DictionaryMatchFrames], in query: DictionaryMatchFrames, limit: Int = 3) -> [Hit] {
        guard let prepared = self.prepare(query) else { return [] }
        return self.hits(references: references, in: prepared, limit: limit)
    }

    static func hits(references: [DictionaryMatchFrames], in query: Query, limit: Int = 3) -> [Hit] {
        self.hits(words: [references], in: query, limit: limit).first ?? []
    }

    /// Every dictionary word's recordings against one dictation. All recording frames are compared
    /// with the dictation in a single matrix multiply, about 7x faster than one multiply per recording
    /// (100 words: 0.8 ms instead of 5.5 ms on an M-series Mac).
    static func hits(words: [[DictionaryMatchFrames]], in query: Query, limit: Int = 3) -> [[Hit]] {
        let m = query.count, hidden = query.hiddenSize
        let usable = words.map { references in
            references.filter {
                $0.hiddenSize == hidden && !$0.values.isEmpty && $0.values.count == $0.count * hidden && $0.values.allSatisfy(\.isFinite)
            }
        }
        let totalRows = usable.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        guard m > 0, totalRows > 0 else { return words.map { _ in [] } }
        var stacked = [Float]()
        stacked.reserveCapacity(totalRows * hidden)
        for references in usable {
            for reference in references {
                stacked += self.normalizedRows(reference)
            }
        }
        var similarity = [Float](repeating: 0, count: totalRows * m)
        stacked.withUnsafeBufferPointer { r in
            query.values.withUnsafeBufferPointer { q in
                similarity.withUnsafeMutableBufferPointer { s in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,
                        CblasTrans,
                        Int32(totalRows),
                        Int32(m),
                        Int32(hidden),
                        1,
                        r.baseAddress,
                        Int32(hidden),
                        q.baseAddress,
                        Int32(hidden),
                        0,
                        s.baseAddress,
                        Int32(m)
                    )
                }
            }
        }
        var row = 0
        return similarity.withUnsafeBufferPointer { sim in
            usable.map { references in
                var bestDistance = [Float](repeating: .infinity, count: m)
                var bestStart = [Int](repeating: 0, count: m)
                for reference in references {
                    let n = reference.count
                    let (distances, starts) = self.endScores(similarity: UnsafeBufferPointer(rebasing: sim[(row * m)..<((row + n) * m)]), rows: n, columns: m)
                    row += n
                    for j in 0..<m where distances[j] < bestDistance[j] {
                        bestDistance[j] = distances[j]
                        bestStart[j] = starts[j]
                    }
                }
                return self.pick(bestDistance: bestDistance, bestStart: bestStart, limit: limit)
            }
        }
    }

    private static func pick(bestDistance: [Float], bestStart: [Int], limit: Int) -> [Hit] {
        let m = bestDistance.count
        var hits: [Hit] = []
        var available = [Bool](repeating: true, count: m)
        while hits.count < limit {
            var candidate: Int?
            for j in 0..<m where available[j] && bestDistance[j] < self.greyZoneLimit {
                if candidate.map({ bestDistance[j] < bestDistance[$0] }) ?? true { candidate = j }
            }
            guard let end = candidate else { break }
            let range = bestStart[end]..<(end + 1)
            hits.append(Hit(frames: range, distance: bestDistance[end]))
            for j in 0..<m where available[j] && (bestStart[j]..<(j + 1)).overlaps(range) {
                available[j] = false
            }
        }
        return hits
    }

    private static func normalizedRows(_ frames: DictionaryMatchFrames) -> [Float] {
        var values = frames.values
        let hidden = frames.hiddenSize
        for row in 0..<frames.count {
            let start = row * hidden
            var norm: Float = 0
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_svesq(base + start, 1, &norm, vDSP_Length(hidden))
            }
            let scale = 1 / max(sqrt(norm), 1e-8)
            for d in start..<(start + hidden) {
                values[d] *= scale
            }
        }
        return values
    }

    /// For every possible end frame in the query: the length-normalized path cost of the best
    /// alignment of the whole reference ending there, and where that alignment starts.
    private static func endScores(similarity: UnsafeBufferPointer<Float>, rows n: Int, columns m: Int) -> ([Float], [Int]) {
        // Two rows swapped in place: no per-row copies, no bounds checks in the hot loop.
        var previousCost = [Float](repeating: 0, count: m), cost = [Float](repeating: 0, count: m)
        var previousStart = Array(0..<m), start = Array(0..<m)
        for j in 0..<m {
            previousCost[j] = 1 - similarity[j]
        }
        let sim = similarity
        for i in 1..<max(1, n) {
            previousCost.withUnsafeBufferPointer { pc in
                previousStart.withUnsafeBufferPointer { ps in
                    cost.withUnsafeMutableBufferPointer { c in
                        start.withUnsafeMutableBufferPointer { st in
                            let row = i * m
                            c[0] = pc[0] + 1 - sim[row]
                            st[0] = ps[0]
                            for j in 1..<max(1, m) {
                                var best = pc[j], from = ps[j]
                                if pc[j - 1] < best { best = pc[j - 1]; from = ps[j - 1] }
                                if c[j - 1] < best { best = c[j - 1]; from = st[j - 1] }
                                c[j] = best + 1 - sim[row + j]
                                st[j] = from
                            }
                        }
                    }
                }
            }
            swap(&previousCost, &cost)
            swap(&previousStart, &start)
        }
        cost = previousCost
        start = previousStart
        var distances = [Float](repeating: .infinity, count: m)
        for j in 0..<m {
            let matched = j + 1 - start[j]
            // A word in a sentence may be up to twice as fast or slow as the recording, no more.
            guard matched * 2 >= n, matched <= n * 2 else { continue }
            distances[j] = cost[j] / Float(matched + n)
        }
        return (distances, start)
    }
}
