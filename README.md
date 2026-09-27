# julia.swift

Run [Supersonic Labs Julia-1](https://huggingface.co/SupersonicLabs/Julia-1) locally from Swift or the `julia` command. Julia-1 answers Choice, Score, and Noul questions about a shared state. It returns probabilities and does not generate text.

The package has no Swift dependencies. Inference uses the [Julia-1 ONNX export](https://huggingface.co/SupersonicLabs/Julia-1-ONNX) on ONNX Runtime's CPU path. A small Rust library runs the Hugging Face tokenizer. Keep one `JuliaModel` instance loaded across requests.

## Install the CLI

The repository is private. Sign in with [GitHub CLI](https://cli.github.com/) using `gh auth login` before installing. The installer downloads the matching desktop build and the model, verifies both against the release SHA-256 checksums, and adds a `julia` command in your user directory. The model download is about 540 MB.

On Apple Silicon macOS or Linux x86_64:

```sh
gh api repos/eastriverlee/julia.swift/contents/Scripts/install.sh \
  -H 'Accept: application/vnd.github.raw+json' | sh
```

The command is placed in `~/.local/bin`, which must be on your `PATH`. Set `XDG_BIN_HOME` to use another command directory. To pin a release, save the script and run `sh install.sh --version v0.1.1`.

On Windows x86_64, run this in PowerShell after `gh auth login`:

```powershell
$installer = gh api repos/eastriverlee/julia.swift/contents/Scripts/install.ps1 -H 'Accept: application/vnd.github.raw+json'
Invoke-Expression ($installer -join "`n")
```

The Windows installer adds `julia.cmd` to your user `PATH`; open a new terminal after installation. Neither Rust nor Swift is required to run a desktop release.

## Manual release files

Each desktop archive contains `julia`, ONNX Runtime, the tokenizer library, and their licenses. Download the matching model archive alongside it from [Releases](https://github.com/eastriverlee/julia.swift/releases):

| Platform | CLI archive |
| --- | --- |
| Apple Silicon macOS | `julia-v0.1.1-macos-arm64.zip` |
| Linux x86_64 | `julia-v0.1.1-linux-x86_64.zip` |
| Windows x86_64 | `julia-v0.1.1-windows-x86_64.zip` |

The model archive is `julia-1-model-82a2fadf8fcc.zip`. Extract the CLI archive, then extract the model archive inside its top-level directory. The resulting layout is `bin/`, `lib/`, and `model/`. Check the downloads against `SHA256SUMS` in the release.

On macOS or Linux, run `./julia` from the extracted directory. On Windows, run `julia.cmd`.

## Decide from the command line

```sh
julia decide \
  --state "The package has not arrived after the promised delivery date." \
  --question "Which team should handle this request?" \
  --option billing="Payment disputes and refunds" \
  --option shipping="Delivery issues"
```

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

The `--state` example returns the selected choice and its probabilities:

```json
{
  "answers": {
    "decision": {
      "choice": "shipping",
      "isApproximate": false,
      "maxProbability": 0.98664784,
      "probabilities": {
        "billing": 0.013352202,
        "shipping": 0.98664784
      },
      "type": "choice"
    }
  },
  "model": "SupersonicLabs/Julia-1"
}
```

`choice` is the selected option key. `probabilities` gives every option's probability; `maxProbability` is the selected option's value. The numbers depend on the input and model files. Add `--probabilities` to print just the probability maps, keyed by question name:

```sh
julia decide \
  --state "The package has not arrived after the promised delivery date." \
  --question "Which team should handle this request?" \
  --option billing="Payment disputes and refunds" \
  --option shipping="Delivery issues" \
  --probabilities
```

```json
{
  "decision": {
    "billing": 0.013352202,
    "shipping": 0.98664784
  }
}
```

For `--input request.json`, the probability-only output has `department`, `severity`, and `urgent` keys. Score uses numeric level indices, and Noul uses `false` and `true` keys.

The answer map uses the same question names. Choice returns `choice` and named `probabilities`; Score returns a zero-based, probability-weighted `score`; Noul returns the probability of true in `noul`. Choice and Score include `maxProbability`. Each answer has `isApproximate`.

The request shape follows [TypeSafe's System One API](https://docs.typesafe.ai/api). The response names the actual local model, `SupersonicLabs/Julia-1`. Julia-1 is a different model from Jev: its probabilities and decisions are not interchangeable with Jev's, and `maxProbability` is not Jev's `confidence`. The local response does not report Jev token usage.

Julia-1 evaluates up to 20 options per model call. For Choice with 21–255 options, the library compares groups of candidates against a shared anchor and combines their relative logits. It returns a probability for every option and sets `isApproximate` to true. Grouped probabilities are estimates; use them with care. Choice keys are sorted before inference so JSON object order does not change the grouping. Score accepts 2–10 ordered levels. Noul uses false then true, with optional `criteria` descriptions for those two values. Structured state, instructions, and descriptions are rendered as JSON text for the model.

## Swift Package Manager

Add `https://github.com/eastriverlee/julia.swift` and link the `JuliaSwift` product. Swift 6.0 or newer is required. A desktop app also needs the model and the two native libraries available at URLs it controls.

```swift
import Foundation
import JuliaSwift

let root = URL(fileURLWithPath: "/path/to/julia-v0.1.1-macos-arm64")
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

## iOS

The `julia-v0.1.1-ios-arm64.zip` release contains `onnxruntime.xcframework` and `JuliaTokenizer.xcframework`. Add both to the app target, add `JuliaSwift` through Swift Package Manager, and bundle the three files from the model archive as app resources. Pass the model resource directory to `JuliaModel(modelDirectoryURL:nativeLibraryDirectoryURL:)`; iOS uses statically linked symbols and ignores the native library URL. The iOS package cross-compiles for arm64. Device inference and memory use require validation in the host app.

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

The benchmark accepts `MODEL_DIRECTORY ONNX_RUNTIME_LIBRARY TOKENIZER_LIBRARY CASES_JSON [BATCH_SIZE] [THREAD_COUNT] [REPETITIONS]`. Set the thread count to `0` for ONNX Runtime's default. Repetitions report the median.

On one local Apple Silicon Mac with ONNX Runtime 1.24.3 CPU, the [author's 100 reference cases](https://huggingface.co/SupersonicLabs/Julia-1-ONNX/blob/main/parity-cases.json) took 1.456 seconds in total after warmup, or 14.56 ms per decision on average. All 100 choices matched, with a maximum absolute logit difference of 0.000174. These figures describe that machine and workload.

The model files come from a pinned revision and are SHA-256 verified by `Scripts/download_model.py`. JuliaSwift and Julia-1 use Apache 2.0 licenses. The ONNX Runtime C headers and binary use Microsoft's MIT license; see [ThirdParty/ONNXRuntime-LICENSE](ThirdParty/ONNXRuntime-LICENSE).
