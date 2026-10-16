import Accelerate
import Foundation

/// Exact (brute-force) nearest-neighbour search over fp16 vectors.
/// Memory: count × dim × 2 bytes (100k × 512 ≈ 100 MB). Scoring converts fixed-size chunks to fp32
/// and runs one matrix-vector product per chunk, so scratch memory stays bounded.
public actor FlatVectorIndex: VectorIndex {
    public nonisolated let modelID: String
    public nonisolated let dimension: Int
    private var ids: [Int64] = []
    private var storage: [Float16] = []      // row-major, ids.count × dimension
    private var slot: [Int64: Int] = [:]
    private let chunkRows = 4096

    public init(modelID: String, dimension: Int) {
        self.modelID = modelID
        self.dimension = dimension
    }

    public func count() -> Int { ids.count }

    public func replaceAll(_ entries: [(id: Int64, vector: [Float16])]) {
        ids.removeAll(keepingCapacity: false)
        storage.removeAll(keepingCapacity: false)
        slot.removeAll(keepingCapacity: false)
        ids.reserveCapacity(entries.count)
        storage.reserveCapacity(entries.count * dimension)
        for e in entries where e.vector.count == dimension {
            if let s = slot[e.id] { overwrite(s, e.vector); continue }
            slot[e.id] = ids.count
            ids.append(e.id)
            storage.append(contentsOf: e.vector)
        }
    }

    public func upsert(id: Int64, vector: [Float]) {
        guard vector.count == dimension else { return }
        let h = vector.map { Float16($0) }
        if let s = slot[id] { overwrite(s, h); return }
        slot[id] = ids.count
        ids.append(id)
        storage.append(contentsOf: h)
    }

    private func overwrite(_ s: Int, _ h: [Float16]) {
        storage.replaceSubrange(s * dimension..<(s + 1) * dimension, with: h)
    }

    /// Swap-remove: O(dim) per id.
    public func remove(ids toRemove: [Int64]) {
        for id in toRemove {
            guard let s = slot.removeValue(forKey: id) else { continue }
            let last = ids.count - 1
            if s != last {
                let lastID = ids[last]
                ids[s] = lastID
                slot[lastID] = s
                for d in 0..<dimension { storage[s * dimension + d] = storage[last * dimension + d] }
            }
            ids.removeLast()
            storage.removeLast(dimension)
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
            let count = rows * dimension
            storage.withUnsafeBufferPointer { src in
                scratch.withUnsafeMutableBufferPointer { dst in
                    var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress! + start * dimension), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
                }
            }
            // scores[rows] = scratch[rows × dim] · query[dim]
            scratch.withUnsafeBufferPointer { a in
                query.withUnsafeBufferPointer { q in
                    scores.withUnsafeMutableBufferPointer { out in
                        vDSP_mmul(a.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
                    }
                }
            }
            for r in 0..<rows { top.offer(id: ids[start + r], score: scores[r]) }
            start += rows
        }
        return top.sorted()
    }
}

/// Bounded min-heap keeping the k best scores.
struct TopK {
    let k: Int
    private var heap: [(id: Int64, score: Float)] = []
    init(k: Int) { self.k = k; heap.reserveCapacity(k) }

    mutating func offer(id: Int64, score: Float) {
        if heap.count < k {
            heap.append((id, score)); siftUp(heap.count - 1)
        } else if score > heap[0].score {
            heap[0] = (id, score); siftDown(0)
        }
    }

    func sorted() -> [(id: Int64, score: Float)] {
        heap.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }

    private mutating func siftUp(_ i: Int) {
        var c = i
        while c > 0 {
            let p = (c - 1) / 2
            if heap[c].score < heap[p].score { heap.swapAt(c, p); c = p } else { return }
        }
    }

    private mutating func siftDown(_ i: Int) {
        var p = i
        while true {
            let l = 2 * p + 1, r = l + 1
            var m = p
            if l < heap.count && heap[l].score < heap[m].score { m = l }
            if r < heap.count && heap[r].score < heap[m].score { m = r }
            if m == p { return }
            heap.swapAt(p, m); p = m
        }
    }
}
