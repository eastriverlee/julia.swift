import Foundation

public enum JuliaJSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case array([JuliaJSONValue])
    case object([String: JuliaJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JuliaJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JuliaJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .boolean(let boolean): try value.encode(boolean)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        case .null: try value.encodeNil()
        }
    }

    func rendered() throws -> String {
        if case .string(let string) = self { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct JuliaEvaluationQuestion: Codable, Sendable {
    public let type: JuliaQuestionType
    public let instructions: JuliaJSONValue
    public let criteria: JuliaJSONValue?

    public init(type: JuliaQuestionType, instructions: JuliaJSONValue, criteria: JuliaJSONValue? = nil) {
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
    }
}

public struct JuliaEvaluationRequest: Codable, Sendable {
    public let state: JuliaJSONValue
    public let questions: [String: JuliaEvaluationQuestion]
    public let model: String?

    public init(state: JuliaJSONValue, questions: [String: JuliaEvaluationQuestion], model: String? = nil) {
        self.state = state
        self.questions = questions
        self.model = model
    }
}

public struct JuliaEvaluationAnswer: Encodable, Sendable {
    public let type: JuliaQuestionType
    public let choice: String?
    public let score: Float?
    public let noul: Float?
    public let probabilities: [String: Float]
    public let maxProbability: Float?
    public let isApproximate: Bool
}

public struct JuliaEvaluationResponse: Encodable, Sendable {
    public let model: String
    public let answers: [String: JuliaEvaluationAnswer]
}

private struct PreparedQuestion {
    let name: String
    let type: JuliaQuestionType
    let instruction: String
    let optionNames: [String]
    let descriptions: [String]
}

private struct PreparedSlice {
    let name: String
    let indices: [Int]
    let request: JuliaQuestion
    let isApproximate: Bool
}

extension JuliaModel {
    public func evaluate(_ request: JuliaEvaluationRequest) throws -> JuliaEvaluationResponse {
        guard !request.questions.isEmpty else {
            throw JuliaError.invalidConfiguration("questions must not be empty")
        }
        let state = try renderState(request.state)
        let prepared = try request.questions.keys.sorted().map { name in
            guard !name.isEmpty, let question = request.questions[name] else {
                throw JuliaError.invalidConfiguration("Question names must not be empty")
            }
            return try prepareQuestion(name: name, question: question)
        }
        let slices = prepared.flatMap { prepareSlices($0, state: state) }
        let decisions = try predict(slices.map(\.request))
        let logitsByName = combineLogits(prepared, slices: slices, decisions: decisions)
        var answers: [String: JuliaEvaluationAnswer] = [:]
        for question in prepared {
            guard let logits = logitsByName[question.name] else {
                throw JuliaError.runtime("Missing logits for \(question.name)")
            }
            answers[question.name] = makeAnswer(question, logits: logits)
        }
        return JuliaEvaluationResponse(model: "SupersonicLabs/Julia-1", answers: answers)
    }

    private func makeAnswer(_ question: PreparedQuestion, logits: [Float]) -> JuliaEvaluationAnswer {
        let peak = logits.max() ?? 0
        let weights = logits.map { exp($0 - peak) }
        let total = weights.reduce(0, +)
        let probabilities = weights.map { $0 / total }
        let distribution = Dictionary(uniqueKeysWithValues: zip(question.optionNames, probabilities))
        let selected = logits.firstIndex(of: peak) ?? 0
        return JuliaEvaluationAnswer(
            type: question.type,
            choice: question.type == .choice ? question.optionNames[selected] : nil,
            score: question.type == .score ? probabilities.enumerated().reduce(0) { $0 + Float($1.offset) * $1.element } : nil,
            noul: question.type == .noul ? probabilities[1] : nil,
            probabilities: distribution,
            maxProbability: question.type == .noul ? nil : probabilities[selected],
            isApproximate: question.optionNames.count > 20
        )
    }

    private func prepareSlices(_ question: PreparedQuestion, state: String) -> [PreparedSlice] {
        if question.optionNames.count <= 20 {
            let request = JuliaQuestion(state: state, question: question.instruction,
                                        options: question.descriptions, type: question.type)
            return [PreparedSlice(name: question.name, indices: Array(question.optionNames.indices),
                                  request: request, isApproximate: false)]
        }
        let candidateIndices = Array(1 ..< question.optionNames.count)
        return stride(from: 0, to: candidateIndices.count, by: 19).map { start in
            let group = Array(candidateIndices[start ..< min(start + 19, candidateIndices.count)])
            let options = [question.descriptions[0]] + group.map { question.descriptions[$0] }
            let request = JuliaQuestion(state: state, question: question.instruction, options: options)
            return PreparedSlice(name: question.name, indices: [0] + group,
                                 request: request, isApproximate: true)
        }
    }

    private func combineLogits(_ questions: [PreparedQuestion], slices: [PreparedSlice],
                               decisions: [JuliaDecision]) -> [String: [Float]] {
        var result = Dictionary(uniqueKeysWithValues: questions.map {
            ($0.name, [Float](repeating: 0, count: $0.optionNames.count))
        })
        for (slice, decision) in zip(slices, decisions) {
            if !slice.isApproximate {
                result[slice.name] = decision.logits
                continue
            }
            for (position, originalIndex) in slice.indices.enumerated().dropFirst() {
                result[slice.name]?[originalIndex] = decision.logits[position] - decision.logits[0]
            }
        }
        return result
    }

    private func renderState(_ value: JuliaJSONValue) throws -> String {
        switch value {
        case .string, .object, .array: try value.rendered()
        default: throw JuliaError.invalidConfiguration("state must be text, an object, or an array")
        }
    }

    private func prepareQuestion(name: String, question: JuliaEvaluationQuestion) throws -> PreparedQuestion {
        let instruction = try renderInstruction(question.instructions)
        let (names, descriptions) = try prepareCriteria(question)
        return PreparedQuestion(name: name, type: question.type, instruction: instruction,
                                optionNames: names, descriptions: descriptions)
    }

    private func renderInstruction(_ value: JuliaJSONValue) throws -> String {
        switch value {
        case .string, .object, .array: try value.rendered()
        default: throw JuliaError.invalidConfiguration("instructions must be text, an object, or an array")
        }
    }

    private func prepareCriteria(_ question: JuliaEvaluationQuestion) throws -> ([String], [String]) {
        switch question.type {
        case .choice:
            guard case .object(let options) = question.criteria, (2...255).contains(options.count),
                  !options.keys.contains("") else {
                throw JuliaError.invalidConfiguration("Choice requires 2–255 named criteria")
            }
            let names = options.keys.sorted()
            return (names, try names.map { name in
                guard let description = options[name] else {
                    throw JuliaError.invalidConfiguration("Missing criterion for \(name)")
                }
                return try renderCriterion(description, fallback: name)
            })
        case .score:
            guard case .array(let levels) = question.criteria, (2...10).contains(levels.count) else {
                throw JuliaError.invalidConfiguration("Score requires 2–10 ordered criteria")
            }
            return (levels.indices.map(String.init), try levels.map { try renderCriterion($0) })
        case .noul:
            guard let criteria = question.criteria else { return (["false", "true"], ["false", "true"]) }
            guard case .object(let options) = criteria, Set(options.keys) == Set(["false", "true"]) else {
                throw JuliaError.invalidConfiguration("Noul criteria must contain false and true")
            }
            return (["false", "true"], try ["false", "true"].map { name in
                guard let description = options[name] else {
                    throw JuliaError.invalidConfiguration("Missing criterion for \(name)")
                }
                return try renderCriterion(description)
            })
        }
    }

    private func renderCriterion(_ value: JuliaJSONValue, fallback: String? = nil) throws -> String {
        switch value {
        case .string, .object, .array:
            let description = try value.rendered()
            guard !description.isEmpty else { throw JuliaError.invalidConfiguration("Criteria must not be empty") }
            return description
        case .null:
            guard let fallback else { throw JuliaError.invalidConfiguration("A criterion needs a description") }
            return fallback
        default: throw JuliaError.invalidConfiguration("Criteria must be text or structured JSON")
        }
    }
}
