import Accelerate
import Foundation

/// Exact search over int8-quantised vectors (Q11: text vectors, 1M × 384 ≈ 370 MB).
/// Each vector stores int8 components and one fp32 scale (max |x| / 127); score = scale · (q · v8).
public actor Int8VectorIndex: VectorIndex {
    public nonisolated let modelID: String
    public nonisolated let dimension: Int
    private var ids: [Int64] = []
    private var storage: [Int8] = []
    private var scales: [Float] = []
    private var slot: [Int64: Int] = [:]
    private let chunkRows = 4096

    public init(modelID: String, dimension: Int) {
        self.modelID = modelID
        self.dimension = dimension
    }

    public func count() -> Int { ids.count }

    static func quantize(_ v: [Float]) -> ([Int8], Float) {
        let m = v.reduce(Float(0)) { max($0, abs($1)) }
        guard m > 0 else { return ([Int8](repeating: 0, count: v.count), 0) }
        let scale = m / 127
        return (v.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) }, scale)
    }

    public func replaceAll(_ entries: [(id: Int64, vector: [Float16])]) {
        ids.removeAll(); storage.removeAll(); scales.removeAll(); slot.removeAll()
        ids.reserveCapacity(entries.count)
        storage.reserveCapacity(entries.count * dimension)
        scales.reserveCapacity(entries.count)
        for e in entries where e.vector.count == dimension { put(e.id, e.vector.map(Float.init)) }
    }

    public func upsert(id: Int64, vector: [Float]) {
        guard vector.count == dimension else { return }
        put(id, vector)
    }

    private func put(_ id: Int64, _ v: [Float]) {
        let (q, scale) = Self.quantize(v)
        if let s = slot[id] {
            storage.replaceSubrange(s * dimension..<(s + 1) * dimension, with: q)
            scales[s] = scale
            return
        }
        slot[id] = ids.count
        ids.append(id)
        storage.append(contentsOf: q)
        scales.append(scale)
    }

    public func remove(ids toRemove: [Int64]) {
        for id in toRemove {
            guard let s = slot.removeValue(forKey: id) else { continue }
            let last = ids.count - 1
            if s != last {
                ids[s] = ids[last]
                slot[ids[s]] = s
                scales[s] = scales[last]
                for d in 0..<dimension { storage[s * dimension + d] = storage[last * dimension + d] }
            }
            ids.removeLast(); scales.removeLast(); storage.removeLast(dimension)
        }
    }

    public func search(_ query: [Float], k: Int) -> [(id: Int64, score: Float)] {
        let n = ids.count
        guard query.count == dimension, n > 0, k > 0 else { return [] }
        var top = TopK(k: k)
        var scratch = [Float](repeating: 0, count: min(chunkRows, n) * dimension)
        var scores = [Float](repeating: 0, count: min(chunkRows, n))
        var start = 0
        while start < n {
            let rows = min(chunkRows, n - start)
            storage.withUnsafeBufferPointer { src in
                scratch.withUnsafeMutableBufferPointer { dst in
                    vDSP_vflt8(src.baseAddress! + start * dimension, 1, dst.baseAddress!, 1, vDSP_Length(rows * dimension))
                }
            }
            scratch.withUnsafeBufferPointer { a in
                query.withUnsafeBufferPointer { q in
                    scores.withUnsafeMutableBufferPointer { out in
                        vDSP_mmul(a.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
                    }
                }
            }
            for r in 0..<rows { top.offer(id: ids[start + r], score: scores[r] * scales[start + r]) }
            start += rows
        }
        return top.sorted()
    }
}
