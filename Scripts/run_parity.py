import os
import pathlib
import platform
import subprocess
import tarfile
import urllib.request
import zipfile

from download_model import FILES, download

RUNTIME_VERSION = "1.24.3"
REFERENCE_DIGEST = "534670f25823f3f9abf9e812500918fabc606682dfd4e2456d827889d9bdca20"


def runtime_details():
    operating_system = platform.system()
    architecture = platform.machine().lower()
    if operating_system == "Linux" and architecture in {"x86_64", "amd64"}:
        return "linux-x64", "tgz", "libonnxruntime.so"
    if operating_system == "Windows" and architecture in {"amd64", "x86_64"}:
        return "win-x64", "zip", "onnxruntime.dll"
    if operating_system == "Darwin" and architecture == "arm64":
        return "osx-arm64", "tgz", "libonnxruntime.dylib"
    raise ValueError(f"Unsupported parity runner: {operating_system} {architecture}")


def download_runtime(directory):
    platform_name, extension, library_name = runtime_details()
    archive_name = f"onnxruntime-{platform_name}-{RUNTIME_VERSION}.{extension}"
    library = directory / f"onnxruntime-{platform_name}-{RUNTIME_VERSION}" / "lib" / library_name
    if library.exists():
        return library
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / archive_name
    url = f"https://github.com/microsoft/onnxruntime/releases/download/v{RUNTIME_VERSION}/{archive_name}"
    urllib.request.urlretrieve(url, archive)
    if extension == "zip":
        with zipfile.ZipFile(archive) as contents:
            contents.extractall(directory)
    else:
        with tarfile.open(archive, "r:gz") as contents:
            contents.extractall(directory)
    return library


def main():
    repository = pathlib.Path(__file__).resolve().parent.parent
    model_directory = repository / "Models" / "Julia-1"
    model_directory.mkdir(parents=True, exist_ok=True)
    for name, checksum in FILES.items():
        download(model_directory, name, checksum)
    download(model_directory, "parity-cases.json", REFERENCE_DIGEST)
    runtime_library = download_runtime(repository / "Models" / "runtime")
    extension = {"Windows": ".dll", "Linux": ".so", "Darwin": ".dylib"}[platform.system()]
    tokenizer_library = repository / "Native" / "tokenizer" / "target" / "release" / f"libjulia_tokenizer{extension}"
    if platform.system() == "Windows":
        tokenizer_library = tokenizer_library.with_name("julia_tokenizer.dll")
    environment = os.environ.copy()
    environment["JULIA_MODEL_DIR"] = str(model_directory)
    environment["ONNX_RUNTIME_LIBRARY"] = str(runtime_library)
    environment["JULIA_TOKENIZER_LIBRARY"] = str(tokenizer_library)
    subprocess.run(["swift", "test", "--disable-sandbox"], cwd=repository, env=environment, check=True)
    subprocess.run([
        "swift", "run", "--disable-sandbox", "-c", "release", "julia-benchmark", str(model_directory),
        str(runtime_library), str(tokenizer_library), str(model_directory / "parity-cases.json"),
    ], cwd=repository, env=environment, check=True)


if __name__ == "__main__":
    main()
