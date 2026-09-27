import CJuliaRuntime
import Foundation

public enum JuliaQuestionType: String, Codable, Sendable {
    case choice
    case score
    case noul
}

public enum JuliaExecutionProvider: String, Sendable {
    case cpu = "CPU"
    case coreML = "CoreML"
    case cuda = "CUDA"
    case directML = "DML"
}

public struct JuliaQuestion: Codable, Sendable {
    public let state: String
    public let question: String
    public let options: [String]
    public let type: JuliaQuestionType

    public init(state: String, question: String, options: [String], type: JuliaQuestionType = .choice) {
        self.state = state
        self.question = question
        self.options = options
        self.type = type
    }
}

public struct JuliaDecision: Sendable {
    public let type: JuliaQuestionType
    public let index: Int
    public let logits: [Float]
    public let probabilities: [Float]

    public var score: Float? {
        guard type == .score else { return nil }
        return probabilities.enumerated().reduce(0) { $0 + Float($1.offset) * $1.element }
    }

    public var probabilityOfTrue: Float? {
        type == .noul ? probabilities[1] : nil
    }
}

public enum JuliaError: Error, LocalizedError {
    case invalidConfiguration(String)
    case tokenizer(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .tokenizer(let message), .runtime(let message): message
        }
    }
}

private struct EncodedQuestion: Decodable {
    let ids: [Int64]
    let markers: [Int64]
    let qtype: Int64
}

public final class JuliaModel {
    private let runtime: OpaquePointer
    private let tokenizer: OpaquePointer
    private let maxLength: Int
    private let headLength: Int
    private let maximumBatchSize: Int
    private let strictEncoding: Bool
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(
        modelURL: URL,
        tokenizerURL: URL,
        onnxRuntimeLibraryURL: URL,
        tokenizerLibraryURL: URL,
        maxLength: Int = 1024,
        headLength: Int = 256,
        maximumBatchSize: Int = 8,
        strictEncoding: Bool = true,
        executionProvider: JuliaExecutionProvider = .cpu,
        threadCount: Int32 = 0
    ) throws {
        guard maxLength > headLength + 4, maxLength <= 8192, headLength > 20 else {
            throw JuliaError.invalidConfiguration("maxLength must be at most 8192 and leave room after headLength")
        }
        guard maxLength <= Int(UInt32.max), headLength <= Int(UInt32.max) else {
            throw JuliaError.invalidConfiguration("Sequence dimensions exceed tokenizer limits")
        }
        guard maximumBatchSize > 0 else {
            throw JuliaError.invalidConfiguration("maximumBatchSize must be positive")
        }
        guard let tokenizer = julia_tokenizer_create(tokenizerLibraryURL.path, tokenizerURL.path) else {
            throw JuliaError.tokenizer("Could not allocate tokenizer")
        }
        let tokenizerMessage = String(cString: julia_tokenizer_error(tokenizer))
        guard tokenizerMessage.isEmpty else {
            julia_tokenizer_destroy(tokenizer)
            throw JuliaError.tokenizer(tokenizerMessage)
        }
        guard let runtime = julia_runtime_create(onnxRuntimeLibraryURL.path, modelURL.path,
            executionProvider.rawValue, threadCount) else {
            julia_tokenizer_destroy(tokenizer)
            throw JuliaError.runtime("Could not allocate ONNX Runtime")
        }
        let runtimeMessage = String(cString: julia_runtime_error(runtime))
        guard runtimeMessage.isEmpty else {
            julia_runtime_destroy(runtime)
            julia_tokenizer_destroy(tokenizer)
            throw JuliaError.runtime(runtimeMessage)
        }
        self.runtime = runtime
        self.tokenizer = tokenizer
        self.maxLength = maxLength
        self.headLength = headLength
        self.maximumBatchSize = executionProvider == .coreML ? 1 : maximumBatchSize
        self.strictEncoding = strictEncoding
    }

    deinit {
        julia_runtime_destroy(runtime)
        julia_tokenizer_destroy(tokenizer)
    }

    public func predict(_ questions: [JuliaQuestion]) throws -> [JuliaDecision] {
        guard !questions.isEmpty else { return [] }
        let encoded = try questions.map(encode).enumerated().map { ($0.offset, $0.element) }
            .sorted { $0.1.ids.count < $1.1.ids.count }
        var decisions: [(Int, JuliaDecision)] = []
        decisions.reserveCapacity(questions.count)
        for start in stride(from: 0, to: encoded.count, by: maximumBatchSize) {
            let batch = Array(encoded[start ..< min(start + maximumBatchSize, encoded.count)])
            let results = try predictBatch(batch.map(\.1))
            decisions.append(contentsOf: zip(batch.map(\.0), results))
        }
        return decisions.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func predictBatch(_ encoded: [EncodedQuestion]) throws -> [JuliaDecision] {
        let sequenceLength = (encoded.map(\.ids.count).max()! + 7) / 8 * 8
        let optionCount = encoded.map(\.markers.count).max()!
        let batchSize = encoded.count
        var inputIDs = [Int64](repeating: 0, count: batchSize * sequenceLength)
        var attentionMask = [Int64](repeating: 0, count: batchSize * sequenceLength)
        var markerPositions = [Int64](repeating: 0, count: batchSize * optionCount)
        var markerMask = [Bool](repeating: false, count: batchSize * optionCount)
        let questionTypes = encoded.map(\.qtype)
        for (rowIndex, row) in encoded.enumerated() {
            for (columnIndex, id) in row.ids.enumerated() {
                inputIDs[rowIndex * sequenceLength + columnIndex] = id
                attentionMask[rowIndex * sequenceLength + columnIndex] = 1
            }
            for (columnIndex, position) in row.markers.enumerated() {
                markerPositions[rowIndex * optionCount + columnIndex] = position
                markerMask[rowIndex * optionCount + columnIndex] = true
            }
        }
        var logits = [Float](repeating: 0, count: batchSize * optionCount)
        let succeeded = inputIDs.withUnsafeBufferPointer { ids in
            attentionMask.withUnsafeBufferPointer { attention in
                markerPositions.withUnsafeBufferPointer { positions in
                    markerMask.withUnsafeBufferPointer { markers in
                        questionTypes.withUnsafeBufferPointer { types in
                            logits.withUnsafeMutableBufferPointer { output in
                                julia_runtime_run(runtime, ids.baseAddress, attention.baseAddress,
                                    positions.baseAddress, markers.baseAddress, types.baseAddress,
                                    Int64(batchSize), Int64(sequenceLength), Int64(optionCount), output.baseAddress)
                            }
                        }
                    }
                }
            }
        }
        guard succeeded else { throw JuliaError.runtime(String(cString: julia_runtime_error(runtime))) }
        guard logits.allSatisfy(\.isFinite) else {
            throw JuliaError.runtime("Model produced non-finite logits")
        }
        return encoded.enumerated().map { rowIndex, row in
            let rowLogits = Array(logits[rowIndex * optionCount ..< rowIndex * optionCount + row.markers.count])
            let peak = rowLogits.max() ?? 0
            let weights = rowLogits.map { exp($0 - peak) }
            let total = weights.reduce(0, +)
            let probabilities = weights.map { $0 / total }
            let index = rowLogits.firstIndex(of: peak) ?? 0
            let type: JuliaQuestionType = switch row.qtype {
            case 1: .score
            case 2: .noul
            default: .choice
            }
            return JuliaDecision(type: type, index: index, logits: rowLogits, probabilities: probabilities)
        }
    }

    private func encode(_ question: JuliaQuestion) throws -> EncodedQuestion {
        let request = try jsonEncoder.encode(question)
        let result = String(decoding: request, as: UTF8.self).withCString { text in
            julia_tokenizer_encode(tokenizer, text,
                UInt32(maxLength), UInt32(headLength), strictEncoding)
        }
        guard let result else { throw JuliaError.tokenizer(String(cString: julia_tokenizer_error(tokenizer))) }
        defer { julia_tokenizer_release_string(tokenizer, result) }
        return try jsonDecoder.decode(EncodedQuestion.self, from: Data(bytes: result, count: strlen(result)))
    }
}
