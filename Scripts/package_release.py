import argparse
import json
import pathlib
import platform
import shutil
import subprocess
import tempfile
import zipfile

from run_parity import download_runtime


def platform_name():
    operating_system = platform.system()
    architecture = platform.machine().lower()
    if operating_system == "Darwin" and architecture == "arm64":
        return "macos-arm64", "julia", "libjulia_tokenizer.dylib"
    if operating_system == "Linux" and architecture in {"x86_64", "amd64"}:
        return "linux-x86_64", "julia", "libjulia_tokenizer.so"
    if operating_system == "Windows" and architecture in {"amd64", "x86_64"}:
        return "windows-x86_64", "julia.exe", "julia_tokenizer.dll"
    raise ValueError(f"Unsupported release platform: {operating_system} {architecture}")


def swift_libraries(directory):
    if platform.system() == "Darwin":
        return
    details = json.loads(subprocess.check_output(["swiftc", "-print-target-info"], text=True))
    suffix = ".dll" if platform.system() == "Windows" else ".so"
    for name in details["paths"]["runtimeLibraryPaths"]:
        source = pathlib.Path(name)
        if not source.exists():
            continue
        for library in source.iterdir():
            if suffix not in library.name or not library.is_file():
                continue
            if platform.system() == "Linux" and not library.name.startswith(("libswift", "libFoundation", "libdispatch", "libBlocksRuntime", "lib_Internal", "lib_Foundation")):
                continue
            shutil.copy2(library, directory / library.name)


def package(version, output_directory):
    repository = pathlib.Path(__file__).resolve().parent.parent
    name, executable_name, tokenizer_name = platform_name()
    runtime = download_runtime(repository / "Models" / "runtime")
    executable = repository / ".build" / "release" / executable_name
    tokenizer = repository / "Native" / "tokenizer" / "target" / "release" / tokenizer_name
    output_directory.mkdir(parents=True, exist_ok=True)
    archive = output_directory / f"julia-{version}-{name}.zip"
    with tempfile.TemporaryDirectory() as temporary_name:
        root = pathlib.Path(temporary_name) / f"julia-{version}-{name}"
        binary_directory = root / "bin"
        library_directory = root / "lib"
        binary_directory.mkdir(parents=True)
        library_directory.mkdir()
        shutil.copy2(executable, binary_directory / executable_name)
        shutil.copy2(tokenizer, library_directory / tokenizer_name)
        shutil.copy2(runtime, library_directory / runtime.name)
        swift_libraries(library_directory)
        shutil.copy2(repository / "LICENSE", root / "LICENSE")
        shutil.copy2(repository / "ThirdParty" / "ONNXRuntime-LICENSE", root / "ONNXRuntime-LICENSE")
        shutil.copy2(repository / "README.md", root / "README.md")
        (root / "model").mkdir()
        (root / "model" / "README.txt").write_text("Extract the julia-1-model release asset into this directory.\n")
        if name.startswith("linux"):
            launcher = root / "julia"
            launcher.write_text('#!/bin/sh\nroot="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"\nLD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$root/bin/julia" "$@"\n')
            launcher.chmod(0o755)
        elif name.startswith("macos"):
            launcher = root / "julia"
            launcher.write_text('#!/bin/sh\nroot="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"\nexec "$root/bin/julia" "$@"\n')
            launcher.chmod(0o755)
        else:
            (root / "julia.cmd").write_text("@echo off\r\nset PATH=%~dp0lib;%PATH%\r\n\"%~dp0bin\\julia.exe\" %*\r\n")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for file in sorted(root.rglob("*")):
                if file.is_file():
                    output.write(file, file.relative_to(root.parent))
    return archive


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
    arguments = parser.parse_args()
    print(package(arguments.version, arguments.output))


if __name__ == "__main__":
    main()
