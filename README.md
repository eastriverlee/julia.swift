# Julia-1 for Swift

Fast decisions on your own CPU. Free to run offline after installation. [Supersonic Labs Julia-1](https://huggingface.co/SupersonicLabs/Julia-1) follows the System One pattern: give it a situation, a question, and possible answers to get a choice, score, or yes/no probability. It handles the same kinds of typed questions as [Jev](https://docs.typesafe.ai/api) through a familiar request shape, using its own model and probabilities.

Run it from Swift on macOS, iOS, Linux, or Windows, or use the `julia` CLI on desktop. Inference needs no network connection or per-request API fee once the model is installed. The Swift package has no Swift dependencies; it uses [ONNX Runtime](https://onnxruntime.ai/) on the CPU and a Rust tokenizer. See the [benchmark](#benchmark) for measured speed.

## Quickstart

On Apple Silicon macOS or Linux x86_64, install the CLI and model:

```sh
curl -fsSL https://raw.githubusercontent.com/eastriverlee/julia.swift/main/Scripts/install.sh | sh
```

Ask a question:

```sh
julia decide \
  --state "The package has not arrived after the promised delivery date." \
  --question "Which team should handle this request?" \
  --option billing="Payment disputes and refunds" \
  --option shipping="Delivery issues"
```

```text
shipping
```

Add `--probabilities` to the command for the option scores:

```text
shipping (billing: 0.013352202, shipping: 0.98664784)
```

The installer verifies release checksums and puts `julia` in `~/.local/bin`. Add that directory to your `PATH` if needed, or set `XDG_BIN_HOME` before installing. The model download is about 540 MB.

On Windows x86_64, run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/eastriverlee/julia.swift/main/Scripts/install.ps1 | iex
```

The Windows installer adds `julia.cmd` to your user `PATH`; open a new terminal after installation. Neither Rust nor Swift is required to run a desktop release.

## Julia-1 vs Jev

| Measure | Julia-1 with julia.swift | Jev |
| --- | --- | --- |
| Deployment | Local CPU, offline after installation | Hosted API |
| Price (input / output per 1M tokens) | Free | [$0.042 / $0](https://typesafe.ai/blog/introducing-system-one-models-and-jev) |
| Speed | 14.56 ms/decision (M4 Pro CPU) | [70–500 ms/request (API)](https://typesafe.ai/blog/introducing-system-one-models-and-jev) |
| Typed decisions | 73.15% | 72.70% |
| AG News pilot, 100 examples | 94% | 91% |
| Emotion pilot, 100 examples | 86% | 48% |
| Banking77 pilot, 100 examples | 64% | 87% |

Accuracy figures come from the [Julia-1 model card](https://huggingface.co/SupersonicLabs/Julia-1), measured on the original checkpoint with H200 BF16 inference on September 24, 2026. The Jev values are those reported in that card. Banking77 used a ranking and top-16 shortlist. Jev's price and latency are TypeSafe's published figures from September 15, 2026. Validation of this Swift runtime covers 100 matching choices; the full accuracy suite describes the original runtime. The speed figures use different hardware, workloads, and measurement methods. Read each as a measurement of its own setup.

## CLI requests

The CLI also reads a Jev-shaped request from a file or standard input:

```sh
julia decide --input request.json
cat request.json | julia decide --input -
```

```json
{
  "state": { "ticket": "The customer was charged twice." },
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this request?",
      "criteria": {
        "billing": "Payment disputes and refunds",
        "shipping": "Delivery issues"
      }
    },
    "urgent": {
      "type": "noul",
      "instructions": "Does this require immediate attention?"
    },
    "severity": {
      "type": "score",
      "instructions": "How severe is the problem?",
      "criteria": ["Low", "Moderate", "High"]
    }
  }
}
```

With several questions, the CLI prints one answer per line in question-name order. For `request.json` above, those lines are `department`, `severity`, then `urgent`. Score prints its probability-weighted numeric score; Noul prints the probability of true. The displayed values depend on the input and model files.

## Swift Package Manager

Add `https://github.com/eastriverlee/julia.swift` and link the `JuliaSwift` product. Swift 6.0 or newer is required. A desktop app also needs the model and the two native libraries available at URLs it controls.

```swift
import Foundation
import JuliaSwift

let root = URL(fileURLWithPath: "/path/to/julia-v0.1.3-macos-arm64")
let model = try JuliaModel(
    modelDirectoryURL: root.appendingPathComponent("model"),
    nativeLibraryDirectoryURL: root.appendingPathComponent("lib")
)
let request = JuliaEvaluationRequest(
    state: .string("The customer was charged twice."),
    questions: [
        "department": JuliaEvaluationQuestion(
            type: .choice,
            instructions: .string("Which team should handle this request?"),
            criteria: .object([
                "billing": .string("Payment disputes and refunds"),
                "shipping": .string("Delivery issues")
            ])
        )
    ]
)
if let answer = try model.evaluate(request).answers["department"] {
    print(answer.choice ?? "No answer")
    print(answer.probabilities)
}
```

For indexed options or raw logits, use `predict([JuliaQuestion])`. Its results preserve question and option order. The default context limit is 1,024 tokens with a 256-token question and option budget. Strict encoding rejects truncation, options longer than 48 tokens, and the reserved `<mask>` marker. `maxLength`, `headLength`, `maximumBatchSize`, and `threadCount` can be set when constructing `JuliaModel`.

### API behavior

The answer map uses the same question names. Choice returns `choice` and named `probabilities`; Score returns a zero-based, probability-weighted `score`; Noul returns the probability of true in `noul`. Choice and Score include `maxProbability`. Each answer has `isApproximate`.

The request shape follows [TypeSafe's System One API](https://docs.typesafe.ai/api). The response names the actual local model, `SupersonicLabs/Julia-1`. Julia-1 is a different model from Jev: its probabilities and decisions are not interchangeable with Jev's, and `maxProbability` is not Jev's `confidence`. The local response does not report Jev token usage.

Julia-1 evaluates up to 20 options per model call. For Choice with 21–255 options, the library compares groups of candidates against a shared anchor and combines their relative logits. It returns a probability for every option and sets `isApproximate` to true. Grouped probabilities are estimates; use them with care. Choice keys are sorted before inference so JSON object order does not change the grouping. Score accepts 2–10 ordered levels. Noul uses false then true, with optional `criteria` descriptions for those two values. Structured state, instructions, and descriptions are rendered as JSON text for the model.

## iOS

The `julia-v0.1.3-ios-arm64.zip` release contains `onnxruntime.xcframework` and `JuliaTokenizer.xcframework`. Add both to the app target, add `JuliaSwift` through Swift Package Manager, and bundle the three files from the model archive as app resources. Pass the model resource directory to `JuliaModel(modelDirectoryURL:nativeLibraryDirectoryURL:)`; iOS uses statically linked symbols and ignores the native library URL. The iOS package cross-compiles for arm64. Device inference and memory use require validation in the host app.

## Manual release files

Each desktop archive contains `julia`, ONNX Runtime, the tokenizer library, and their licenses. Download the matching model archive alongside it from [Releases](https://github.com/eastriverlee/julia.swift/releases):

| Platform | CLI archive |
| --- | --- |
| Apple Silicon macOS | `julia-v0.1.3-macos-arm64.zip` |
| Linux x86_64 | `julia-v0.1.3-linux-x86_64.zip` |
| Windows x86_64 | `julia-v0.1.3-windows-x86_64.zip` |

The model archive is `julia-1-model-82a2fadf8fcc.zip`. Extract the CLI archive, then extract the model archive inside its top-level directory. The resulting layout is `bin/`, `lib/`, and `model/`. Check the downloads against `SHA256SUMS` in the release.

On macOS or Linux, run `./julia` from the extracted directory. On Windows, run `julia.cmd`.

## Build and verify from source

```sh
python3 Scripts/download_model.py Models/Julia-1
cargo build --release --locked --manifest-path Native/tokenizer/Cargo.toml
swift test
swift build -c release --product julia
```

Use the paths for your platform when running integration tests:

```sh
JULIA_MODEL_DIR="$PWD/Models/Julia-1" \
ONNX_RUNTIME_LIBRARY="/path/to/libonnxruntime.dylib" \
JULIA_TOKENIZER_LIBRARY="$PWD/Native/tokenizer/target/release/libjulia_tokenizer.dylib" \
swift test
```

### Benchmark

The benchmark accepts `MODEL_DIRECTORY ONNX_RUNTIME_LIBRARY TOKENIZER_LIBRARY CASES_JSON [BATCH_SIZE] [THREAD_COUNT] [REPETITIONS]`. Set the thread count to `0` for ONNX Runtime's default. Repetitions report the median.

The M4 Pro CPU measurement used ONNX Runtime 1.24.3 and the [author's 100 reference cases](https://huggingface.co/SupersonicLabs/Julia-1-ONNX/blob/main/parity-cases.json) after warmup. All choices matched, with a maximum absolute logit difference of 0.000174. The timing describes that machine and workload.

The model files come from a pinned revision and are SHA-256 verified by `Scripts/download_model.py`. JuliaSwift and Julia-1 use Apache 2.0 licenses. The ONNX Runtime C headers and binary use Microsoft's MIT license; see [ThirdParty/ONNXRuntime-LICENSE](ThirdParty/ONNXRuntime-LICENSE).
