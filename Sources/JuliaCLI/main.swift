import Foundation
import JuliaSwift

private struct Options {
    var input: String?
    var state: String?
    var instruction: String?
    var type: JuliaQuestionType = .choice
    var options: [String: JuliaJSONValue] = [:]
    var levels: [JuliaJSONValue] = []
    var modelDirectory: String?
    var runtimeLibrary: String?
    var tokenizerLibrary: String?
    var isProbabilitiesOnly = false
    var isHelpRequested = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "decide" { index += 1; continue }
            if argument == "--help" || argument == "-h" { isHelpRequested = true; return }
            if argument == "--probabilities" { isProbabilitiesOnly = true; index += 1; continue }
            guard index + 1 < arguments.count else {
                throw JuliaError.invalidConfiguration("Missing value for \(argument)")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--input": input = value
            case "--state": state = value
            case "--question": instruction = value
            case "--type":
                guard let parsed = JuliaQuestionType(rawValue: value) else {
                    throw JuliaError.invalidConfiguration("type must be choice, score, or noul")
                }
                type = parsed
            case "--option":
                guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                    throw JuliaError.invalidConfiguration("--option must be NAME=DESCRIPTION")
                }
                options[String(value[..<separator])] = .string(String(value[value.index(after: separator)...]))
            case "--level": levels.append(.string(value))
            case "--false": options["false"] = .string(value)
            case "--true": options["true"] = .string(value)
            case "--model-dir": modelDirectory = value
            case "--runtime-library": runtimeLibrary = value
            case "--tokenizer-library": tokenizerLibrary = value
            default: throw JuliaError.invalidConfiguration("Unknown argument: \(argument)")
            }
            index += 2
        }
    }

    func request() throws -> JuliaEvaluationRequest {
        if let input {
            let data = try input == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data(contentsOf: URL(fileURLWithPath: input))
            return try JSONDecoder().decode(JuliaEvaluationRequest.self, from: data)
        }
        guard let state, let instruction else {
            throw JuliaError.invalidConfiguration("Provide --input or both --state and --question")
        }
        let criteria: JuliaJSONValue? = switch type {
        case .choice, .noul: options.isEmpty ? nil : .object(options)
        case .score: .array(levels)
        }
        let question = JuliaEvaluationQuestion(type: type, instructions: .string(instruction), criteria: criteria)
        return JuliaEvaluationRequest(state: .string(state), questions: ["decision": question])
    }
}

@main private enum JuliaCommand {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.isHelpRequested {
                print("Usage: julia decide --input FILE|- [--probabilities] [--model-dir DIR]\n       julia decide --state TEXT --question TEXT --type choice --option NAME=DESCRIPTION --option NAME=DESCRIPTION [--probabilities]")
                return
            }
            let request = try options.request()
            let model = try loadModel(options)
            let response = try model.evaluate(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data: Data
            if options.isProbabilitiesOnly {
                data = try encoder.encode(response.answers.mapValues(\.probabilities))
            } else {
                data = try encoder.encode(response)
            }
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("julia: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func loadModel(_ options: Options) throws -> JuliaModel {
        let environment = ProcessInfo.processInfo.environment
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let releaseDirectory = executableDirectory.deletingLastPathComponent()
        let modelDirectory = options.modelDirectory ?? environment["JULIA_MODEL_DIR"]
            ?? releaseDirectory.appendingPathComponent("model").path
        let librarySuffix: String
        let runtimeName: String
        #if os(Windows)
        librarySuffix = ".dll"
        runtimeName = "onnxruntime.dll"
        #elseif os(macOS)
        librarySuffix = ".dylib"
        runtimeName = "libonnxruntime.dylib"
        #else
        librarySuffix = ".so"
        runtimeName = "libonnxruntime.so"
        #endif
        let runtimeLibrary = options.runtimeLibrary ?? environment["ONNX_RUNTIME_LIBRARY"]
            ?? releaseDirectory.appendingPathComponent("lib/\(runtimeName)").path
        let tokenizerName = librarySuffix == ".dll" ? "julia_tokenizer.dll" : "libjulia_tokenizer\(librarySuffix)"
        let tokenizerLibrary = options.tokenizerLibrary ?? environment["JULIA_TOKENIZER_LIBRARY"]
            ?? releaseDirectory.appendingPathComponent("lib/\(tokenizerName)").path
        let directory = URL(fileURLWithPath: modelDirectory)
        return try JuliaModel(
            modelURL: directory.appendingPathComponent("model.onnx"),
            tokenizerURL: directory.appendingPathComponent("tokenizer.json"),
            onnxRuntimeLibraryURL: URL(fileURLWithPath: runtimeLibrary),
            tokenizerLibraryURL: URL(fileURLWithPath: tokenizerLibrary)
        )
    }
}
