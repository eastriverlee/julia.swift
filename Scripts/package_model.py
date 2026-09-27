import argparse
import pathlib
import zipfile

from download_model import FILES, REVISION, download


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist"))
    arguments = parser.parse_args()
    repository = pathlib.Path(__file__).resolve().parent.parent
    model_directory = repository / "Models" / "Julia-1"
    model_directory.mkdir(parents=True, exist_ok=True)
    for name, checksum in FILES.items():
        download(model_directory, name, checksum)
    arguments.output.mkdir(parents=True, exist_ok=True)
    archive = arguments.output / f"julia-1-model-{REVISION[:12]}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for name in FILES:
            output.write(model_directory / name, f"model/{name}")
    print(archive)


if __name__ == "__main__":
    main()
