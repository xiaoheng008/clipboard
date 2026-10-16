import Foundation

/// Contract: `embeddings.vec` is little-endian IEEE fp16, L2-normalised, `dim` values.
public enum VectorCodec {
    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    public static func encode(_ v: [Float]) -> Data {
        var halves = v.map { Float16($0).bitPattern.littleEndian }
        return Data(bytes: &halves, count: halves.count * 2)
    }

    public static func decodeHalves(_ d: Data) -> [Float16] {
        let n = d.count / 2
        return d.withUnsafeBytes { raw in
            (0..<n).map { Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))) }
        }
    }

    public static func decode(_ d: Data) -> [Float] { decodeHalves(d).map(Float.init) }
}
