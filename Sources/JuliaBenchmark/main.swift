import Foundation
import JuliaSwift

struct ReferenceCase: Decodable {
    let request: JuliaQuestion
    let pytorchLogits: [Float]

    enum CodingKeys: String, CodingKey {
        case request
        case pytorchLogits = "pytorch_logits"
    }
}

let arguments = CommandLine.arguments
guard (5...8).contains(arguments.count) else {
    fatalError("Usage: julia-benchmark MODEL_DIRECTORY ONNX_RUNTIME_LIBRARY TOKENIZER_LIBRARY CASES_JSON [BATCH_SIZE] [THREAD_COUNT] [REPETITIONS]")
}
let batchSize = arguments.count > 5 ? Int(arguments[5]) : 8
let threadCount = arguments.count > 6 ? Int32(arguments[6]) : 0
let repetitions = arguments.count > 7 ? Int(arguments[7]) : 1
guard let batchSize, batchSize > 0, let threadCount, threadCount >= 0,
      let repetitions, repetitions > 0 else {
    fatalError("Batch size and repetitions must be positive; thread count must be nonnegative")
}
let directory = URL(fileURLWithPath: arguments[1])
let model = try JuliaModel(
    modelURL: directory.appendingPathComponent("model.onnx"),
    tokenizerURL: directory.appendingPathComponent("tokenizer.json"),
    onnxRuntimeLibraryURL: URL(fileURLWithPath: arguments[2]),
    tokenizerLibraryURL: URL(fileURLWithPath: arguments[3]),
    maximumBatchSize: batchSize,
    threadCount: threadCount
)
let cases = try JSONDecoder().decode([ReferenceCase].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[4])))
guard !cases.isEmpty else { fatalError("Reference case list is empty") }
_ = try model.predict([cases[0].request])
let requests = cases.map(\.request)
var durations: [Double] = []
var decisions: [JuliaDecision] = []
for _ in 0 ..< repetitions {
    let start = ProcessInfo.processInfo.systemUptime
    decisions = try model.predict(requests)
    durations.append(ProcessInfo.processInfo.systemUptime - start)
}
let sortedDurations = durations.sorted()
let duration = (sortedDurations[(sortedDurations.count - 1) / 2] + sortedDurations[sortedDurations.count / 2]) / 2
let matches = zip(decisions, cases).filter { decision, reference in
    decision.index == reference.pytorchLogits.firstIndex(of: reference.pytorchLogits.max() ?? 0)
}.count
let maximumDifference = zip(decisions, cases).flatMap { decision, reference in
    zip(decision.logits, reference.pytorchLogits).map { abs($0 - $1) }
}.max() ?? 0
print("\(cases.count) decisions in \(String(format: "%.3f", duration)) s (median of \(repetitions))")
print("\(String(format: "%.2f", duration * 1000 / Double(cases.count))) ms/decision")
print("\(matches)/\(cases.count) reference choices; max logit difference \(maximumDifference)")
guard matches == cases.count, maximumDifference < 0.02 else {
    fatalError("Julia output did not match the reference cases")
}
