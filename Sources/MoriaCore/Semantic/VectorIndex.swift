import Accelerate
import Foundation
import GRDB

/// Stores vectors as little-endian Float16 blobs (half the size of Float32, no measurable
/// loss for cosine ranking).
enum VectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        let halves = vector.map { Float16($0) }
        return halves.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data, into buffer: inout [Float16]) {
        data.withUnsafeBytes { raw in
            buffer.append(contentsOf: raw.bindMemory(to: Float16.self))
        }
    }
}

/// Brute-force cosine search over all chunk vectors, held in memory as Float16.
///
/// A few hundred thousand chunks scan in tens of milliseconds with vDSP; that is simpler and
/// exact compared with an approximate index, and fits the number of documents Moria embeds.
final class VectorIndex: Sendable {
    let version: Int
    private let fileIDs: [Int64]
    private let chunks: [Int32]
    private let vectors: [Float16]
    private let dimension: Int

    init(database: IndexDatabase) throws {
        var ids: [Int64] = []
        var chunkNumbers: [Int32] = []
        var vectors: [Float16] = []
        var dimension = 0
        let version = try database.pool.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT fileId, chunk, vec FROM chunk_vec")
            while let row = try cursor.next() {
                let data: Data = row["vec"]
                let length = data.count / MemoryLayout<Float16>.size
                if dimension == 0 { dimension = length }
                guard length == dimension else { continue }
                ids.append(row["fileId"])
                chunkNumbers.append(row["chunk"])
                VectorCodec.decode(data, into: &vectors)
            }
            return try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'embeddings.version'") ?? 0
        }
        self.version = version
        fileIDs = ids
        chunks = chunkNumbers
        self.vectors = vectors
        self.dimension = dimension
    }

    var isEmpty: Bool { fileIDs.isEmpty }

    struct Hit {
        var fileID: Int64
        var score: Float
        /// The file's closest chunk.
        var chunk: Int
    }

    struct Ranking {
        /// Files by their best chunk's cosine similarity, highest first.
        var hits: [Hit]
        /// Mean and standard deviation of all chunk similarities, to judge which hits stand out.
        var mean: Float
        var deviation: Float
        /// Number of chunks compared.
        var count: Int
    }

    func search(_ query: [Float], limit: Int) -> Ranking {
        guard !fileIDs.isEmpty, query.count == dimension else { return Ranking(hits: [], mean: 0, deviation: 0, count: 0) }
        let blockRows = 4096
        var scores = [Float](repeating: 0, count: fileIDs.count)
        var block = [Float](repeating: 0, count: blockRows * dimension)
        vectors.withUnsafeBufferPointer { halves in
            block.withUnsafeMutableBufferPointer { floats in
                scores.withUnsafeMutableBufferPointer { out in
                    var start = 0
                    while start < fileIDs.count {
                        let rows = min(blockRows, fileIDs.count - start)
                        let count = rows * dimension
                        // Float16 -> Float32, then scores = block (rows x dim) * query (dim x 1).
                        var source = vImage_Buffer(
                            data: UnsafeMutableRawPointer(mutating: halves.baseAddress! + start * dimension),
                            height: 1, width: vImagePixelCount(count), rowBytes: count * 2
                        )
                        var destination = vImage_Buffer(
                            data: floats.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4
                        )
                        vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
                        vDSP_mmul(
                            floats.baseAddress!, 1, query, 1, out.baseAddress! + start, 1,
                            vDSP_Length(rows), 1, vDSP_Length(dimension)
                        )
                        start += rows
                    }
                }
            }
        }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(scores, 1, nil, 1, &mean, &deviation, vDSP_Length(scores.count))
        var best: [Int64: Hit] = [:]
        for (index, score) in scores.enumerated() {
            let id = fileIDs[index]
            if score > best[id]?.score ?? -1 { best[id] = Hit(fileID: id, score: score, chunk: Int(chunks[index])) }
        }
        let hits = Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
        return Ranking(hits: hits, mean: mean, deviation: deviation, count: scores.count)
    }
}
