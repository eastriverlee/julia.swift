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
guard arguments.count == 5 else {
    fatalError("Usage: julia-benchmark MODEL_DIRECTORY ONNX_RUNTIME_LIBRARY TOKENIZER_LIBRARY CASES_JSON")
}
let directory = URL(fileURLWithPath: arguments[1])
let model = try JuliaModel(
    modelURL: directory.appendingPathComponent("model.onnx"),
    tokenizerURL: directory.appendingPathComponent("tokenizer.json"),
    onnxRuntimeLibraryURL: URL(fileURLWithPath: arguments[2]),
    tokenizerLibraryURL: URL(fileURLWithPath: arguments[3])
)
let cases = try JSONDecoder().decode([ReferenceCase].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[4])))
guard !cases.isEmpty else { fatalError("Reference case list is empty") }
_ = try model.predict([cases[0].request])
let start = ProcessInfo.processInfo.systemUptime
let decisions = try model.predict(cases.map(\.request))
let duration = ProcessInfo.processInfo.systemUptime - start
let matches = zip(decisions, cases).filter { decision, reference in
    decision.index == reference.pytorchLogits.firstIndex(of: reference.pytorchLogits.max() ?? 0)
}.count
let maximumDifference = zip(decisions, cases).flatMap { decision, reference in
    zip(decision.logits, reference.pytorchLogits).map { abs($0 - $1) }
}.max() ?? 0
print("\(cases.count) decisions in \(String(format: "%.3f", duration)) s")
print("\(String(format: "%.2f", duration * 1000 / Double(cases.count))) ms/decision")
print("\(matches)/\(cases.count) reference choices; max logit difference \(maximumDifference)")
guard matches == cases.count, maximumDifference < 0.02 else {
    fatalError("Julia output did not match the reference cases")
}
