import Foundation
import JuliaSwift
import Testing

@Suite(.serialized) struct JuliaSwiftTests {
    @Test func rejectsInvalidSequenceBudget() {
        #expect(throws: JuliaError.self) {
            try JuliaModel(
                modelURL: URL(fileURLWithPath: "model.onnx"),
                tokenizerURL: URL(fileURLWithPath: "tokenizer.json"),
                onnxRuntimeLibraryURL: URL(fileURLWithPath: "onnxruntime"),
                tokenizerLibraryURL: URL(fileURLWithPath: "tokenizer"),
                maxLength: 256,
                headLength: 256
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func emptyBatch() throws {
        let model = try loadedModel()
        #expect(try model.predict([]).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func referenceDecision() throws {
        let model = try loadedModel()
        let question = JuliaQuestion(
            state: "",
            question: "Which option correctly fills the blank?\nHe couldn't fit the soda bottle on the refrigerator shelf because the _ was too tall.",
            options: ["shelf", "bottle"]
        )
        let decision = try #require(model.predict([question]).first)
        #expect(decision.index == 1)
        #expect(abs(decision.logits[0] - (-4.739211)) < 0.02)
        #expect(abs(decision.logits[1] - (-1.224170)) < 0.02)
        #expect(abs(decision.probabilities.reduce(0, +) - 1) < 0.00001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func mixedLengthBatchPreservesOrder() throws {
        let model = try loadedModel()
        let questions = [
            JuliaQuestion(state: "", question: "Which option correctly fills the blank?\nShe changed her university course from mathematics to history, because the _ course is more simple.", options: ["history", "mathematics"]),
            JuliaQuestion(state: "", question: "Which option correctly fills the blank?\nHe couldn't fit the soda bottle on the refrigerator shelf because the _ was too tall.", options: ["shelf", "bottle"]),
        ]
        let decisions = try model.predict(questions)
        #expect(decisions.map(\.index) == [0, 1])
        #expect(abs(decisions[0].logits[0] - 0.568046) < 0.02)
        #expect(abs(decisions[1].logits[1] - (-1.224170)) < 0.02)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func reservedMarkerIsRejected() throws {
        let model = try loadedModel()
        let question = JuliaQuestion(state: "<mask>", question: "Choose", options: ["one", "two"])
        #expect(throws: JuliaError.self) { try model.predict([question]) }
    }

    @Test func decodesJevShapedRequest() throws {
        let input = Data(#"{"state":{"ticket":"late"},"model":"jev-latest","questions":{"department":{"type":"choice","instructions":"Choose a team","criteria":{"billing":"Payments","shipping":"Delivery"}}}}"#.utf8)
        let request = try JSONDecoder().decode(JuliaEvaluationRequest.self, from: input)
        #expect(request.questions["department"]?.type == .choice)
        #expect(request.model == "jev-latest")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func namedChoiceMatchesReference() throws {
        let model = try loadedModel()
        let request = JuliaEvaluationRequest(
            state: .string(""),
            questions: ["answer": JuliaEvaluationQuestion(
                type: .choice,
                instructions: .string("Which option correctly fills the blank?\nHe couldn't fit the soda bottle on the refrigerator shelf because the _ was too tall."),
                criteria: .object(["shelf": .string("shelf"), "bottle": .string("bottle")])
            )]
        )
        let answer = try #require(model.evaluate(request).answers["answer"])
        #expect(answer.choice == "bottle")
        #expect(answer.isApproximate == false)
        #expect(abs(answer.probabilities.values.reduce(0, +) - 1) < 0.00001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JULIA_MODEL_DIR"] != nil)) func supportsTwoHundredFiftyFiveChoices() throws {
        let model = try loadedModel()
        let options = Dictionary(uniqueKeysWithValues: (0..<255).map { ("option\($0)", JuliaJSONValue.string("Candidate \($0)")) })
        let request = JuliaEvaluationRequest(state: .string("Choose a candidate."), questions: [
            "selection": JuliaEvaluationQuestion(type: .choice, instructions: .string("Which candidate is best?"), criteria: .object(options))
        ])
        let answer = try #require(model.evaluate(request).answers["selection"])
        #expect(answer.isApproximate)
        #expect(answer.probabilities.count == 255)
        #expect(abs(answer.probabilities.values.reduce(0, +) - 1) < 0.00001)
        #expect(answer.choice.map { options[$0] != nil } == true)
    }

    private func loadedModel() throws -> JuliaModel {
        let environment = ProcessInfo.processInfo.environment
        guard let modelDirectory = environment["JULIA_MODEL_DIR"],
              let runtimeLibrary = environment["ONNX_RUNTIME_LIBRARY"] else {
            throw JuliaError.invalidConfiguration("Set JULIA_MODEL_DIR and ONNX_RUNTIME_LIBRARY for integration tests")
        }
        let root = URL(fileURLWithPath: modelDirectory)
        let tokenizerLibrary = URL(fileURLWithPath: environment["JULIA_TOKENIZER_LIBRARY"]
            ?? "Native/tokenizer/target/release/libjulia_tokenizer.dylib")
        return try JuliaModel(
            modelURL: root.appendingPathComponent("model.onnx"),
            tokenizerURL: root.appendingPathComponent("tokenizer.json"),
            onnxRuntimeLibraryURL: URL(fileURLWithPath: runtimeLibrary),
            tokenizerLibraryURL: tokenizerLibrary
        )
    }
}
