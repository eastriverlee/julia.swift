import argparse
import hashlib
import pathlib
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile


RUNTIME_URL = "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.3.zip"
RUNTIME_DIGEST = "b7eedc45932bac758ffd057cac0feb3f682269e47750b159e4c865145cbf0a8e"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
    arguments = parser.parse_args()
    repository = pathlib.Path(__file__).resolve().parent.parent
    tokenizer = repository / "Native" / "tokenizer" / "target" / "aarch64-apple-ios" / "release" / "libjulia_tokenizer.a"
    arguments.output.mkdir(parents=True, exist_ok=True)
    archive = arguments.output / f"julia-{arguments.version}-ios-arm64.zip"
    with tempfile.TemporaryDirectory() as temporary_name:
        temporary = pathlib.Path(temporary_name)
        runtime_archive = temporary / "onnxruntime.zip"
        urllib.request.urlretrieve(RUNTIME_URL, runtime_archive)
        if hashlib.sha256(runtime_archive.read_bytes()).hexdigest() != RUNTIME_DIGEST:
            raise ValueError("ONNX Runtime iOS archive checksum mismatch")
        root = temporary / f"julia-{arguments.version}-ios-arm64"
        root.mkdir()
        with zipfile.ZipFile(runtime_archive) as runtime:
            for name in runtime.namelist():
                if name.startswith("onnxruntime.xcframework/") or name == "LICENSE":
                    runtime.extract(name, root)
        subprocess.run([
            "xcodebuild", "-create-xcframework", "-library", str(tokenizer),
            "-headers", str(repository / "Native" / "tokenizer" / "include"),
            "-output", str(root / "JuliaTokenizer.xcframework"),
        ], check=True)
        shutil.copy2(repository / "LICENSE", root / "JuliaSwift-LICENSE")
        (root / "README.txt").write_text(
            "Add JuliaSwift from the Swift package and link both XCFrameworks to the app target.\n"
            "Bundle the separate Julia-1 model files and pass their directory to JuliaModel.\n"
            "The binary libraries are for iOS arm64 devices. Device inference has not been validated.\n"
        )
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for file in sorted(root.rglob("*")):
                if file.is_file():
                    output.write(file, file.relative_to(root.parent))
    print(archive)


if __name__ == "__main__":
    main()
