# julia.swift

Swift Package Manager interface for [Supersonic Labs Julia 1](https://huggingface.co/SupersonicLabs/Julia-1), a 144M parameter model that chooses among 2–20 supplied answers. It supports choice, ordered score, and Boolean decisions. It is not a text generation model.

The package has no Swift package dependencies. It uses the author's [ONNX export](https://huggingface.co/SupersonicLabs/Julia-1-ONNX), ONNX Runtime's C API, and a small Rust bridge to the Hugging Face tokenizer. The model stays loaded between calls. Requests are encoded in process, sorted by token length, and run in bounded batches. CPU inference is the recommended starting point on all platforms.

## Requirements

- Swift 6.0 or newer
- Rust and Cargo to build the tokenizer library
- ONNX Runtime 1.24.x native library for the target platform
- About 600 MiB of disk space for the model and tokenizer, plus runtime memory

The model files are downloaded separately and are never committed to this repository. The source code is Apache 2.0 licensed. The model is published under Apache 2.0 by Supersonic Labs.

## Install

Add the package to your app:

```swift
.package(url: "https://github.com/eastriverlee/julia.swift", branch: "main")
```

Add the `JuliaSwift` product to the app target. Download the pinned, SHA-256 verified model files:

```sh
python3 Scripts/download_model.py Models/Julia-1
cargo build --release --locked --manifest-path Native/tokenizer/Cargo.toml
```

The tokenizer library is `Native/tokenizer/target/release/libjulia_tokenizer.dylib` on macOS, `libjulia_tokenizer.so` on Linux, or `julia_tokenizer.dll` on Windows. Obtain ONNX Runtime's native shared library from the [official release](https://github.com/microsoft/onnxruntime/releases/tag/v1.24.3) or an [official install method](https://onnxruntime.ai/docs/install/). Keep ONNX Runtime's provider libraries beside its main library when using GPU providers. The app must make both native libraries available locally; the Swift package loads them from the URLs supplied at initialization.

```swift
import JuliaSwift

let directory = URL(fileURLWithPath: "/path/to/Models/Julia-1")
let model = try JuliaModel(
    modelURL: directory.appendingPathComponent("model.onnx"),
    tokenizerURL: directory.appendingPathComponent("tokenizer.json"),
    onnxRuntimeLibraryURL: URL(fileURLWithPath: "/path/to/libonnxruntime.dylib"),
    tokenizerLibraryURL: URL(fileURLWithPath: "/path/to/libjulia_tokenizer.dylib")
)
let decisions = try model.predict([
    JuliaQuestion(
        state: "The customer was charged twice for the same order.",
        question: "Which team should handle this request?",
        options: ["Billing and payment disputes", "Shipping and delivery", "Account access"]
    )
])
print(decisions[0].index, decisions[0].probabilities)
```

Use the same `JuliaModel` instance for subsequent requests. Results preserve the caller's question and option order. `JuliaDecision` contains raw logits, full softmax probabilities, and the winning index. For `.score`, `score` is the expected zero-based rubric index. For `.noul`, `probabilityOfTrue` is the probability of the second, true option. Supply false then true for `.noul`.

The defaults use strict encoding, a 1,024-token combined context, a 256-token head budget, and batches of up to eight. You can set `maxLength` as high as 8,192, but larger contexts consume more time and memory. Strict encoding rejects truncation, overlong options, and the reserved `<mask>` marker. Clear, distinct option descriptions matter for accuracy.

## Platforms

| Platform | Native runtime integration | Current validation |
| --- | --- | --- |
| macOS | ONNX Runtime and Rust tokenizer shared libraries | Built and tested with real weights on Apple Silicon |
| Linux | ONNX Runtime and Rust tokenizer shared libraries | Package and Rust build checked in CI |
| Windows | ONNX Runtime and Rust tokenizer DLLs | Package and Rust build checked in CI |
| iOS | Statically link ONNX Runtime C and Rust tokenizer libraries into the app | Package cross-compiles for arm64 iOS; device inference needs app integration testing |

On iOS, build the Rust static library with `cargo build --release --target aarch64-apple-ios --manifest-path Native/tokenizer/Cargo.toml`, link `libjulia_tokenizer.a` and the [ONNX Runtime iOS C library](https://onnxruntime.ai/docs/install/) into the app, and bundle the three model files as app resources. The two library URL arguments are ignored on iOS because the symbols are statically linked. An iOS app needs enough storage and RAM for this 551 MB weight file. Run an on-device parity and memory test before release.

`executionProvider: .cuda` and `.directML` select the corresponding ONNX Runtime provider when the installed library includes it. On Apple platforms, `.coreML` is available, but this export needs a single-file ONNX model for CoreML. Create one with an optional offline tool:

```sh
python3 -m pip install onnx
python3 Scripts/inline_model.py Models/Julia-1 Models/Julia-1-inline
```

CoreML runs one request per batch because this export's CoreML partitions have a batch-one shape limit. On the Mac used for validation it was slower than ONNX Runtime CPU. Benchmark on the target hardware before choosing an accelerator.

## Verify and benchmark

```sh
swift test
JULIA_MODEL_DIR="$PWD/Models/Julia-1" \
ONNX_RUNTIME_LIBRARY="/path/to/libonnxruntime.dylib" \
JULIA_TOKENIZER_LIBRARY="$PWD/Native/tokenizer/target/release/libjulia_tokenizer.dylib" \
swift test
```

The second command runs integration tests against the actual weights. The [author's 100 parity cases](https://huggingface.co/SupersonicLabs/Julia-1-ONNX/blob/main/parity-cases.json) can be timed with:

```sh
swift run -c release julia-benchmark Models/Julia-1 /path/to/libonnxruntime.dylib \
  Native/tokenizer/target/release/libjulia_tokenizer.dylib parity-cases.json
```

On the local Apple Silicon Mac with ONNX Runtime 1.24.3 CPU, after one warmup call, the 100 cases took 1.464 seconds (14.64 ms per decision) with 100/100 matching choices and 0.000174 maximum absolute logit difference versus the author's PyTorch reference. This is a single-machine result, not a cross-platform speed claim. The CoreML path with an inlined model took 7.484 seconds for the same 100 cases.

The vendored ONNX Runtime C headers are from version 1.24.3 under Microsoft's MIT license; see [ThirdParty/ONNXRuntime-LICENSE](ThirdParty/ONNXRuntime-LICENSE).
