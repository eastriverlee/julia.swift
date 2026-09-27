import hashlib
import pathlib
import sys
import urllib.request

REVISION = "82a2fadf8fccfccdc5fd4e1009ba8f1a265eb7a8"
FILES = {
    "model.onnx": "97141d0cfb1da6204e9f8f24d581af72eaeb82cda21149d83eaa6df7160fbcd9",
    "model.onnx.data": "fd915be810d7ebfb80fb05a48dd33c9484d17ae1b6bcb9e1f544cbaaa913ded1",
    "tokenizer.json": "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f",
}


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def download(directory, name, expected_digest):
    destination = directory / name
    if destination.exists() and digest(destination) == expected_digest:
        print(f"Verified {destination}")
        return
    temporary = destination.with_suffix(destination.suffix + ".download")
    url = f"https://huggingface.co/SupersonicLabs/Julia-1-ONNX/resolve/{REVISION}/{name}"
    print(f"Downloading {name}", flush=True)
    with urllib.request.urlopen(url) as response, temporary.open("wb") as output:
        for block in iter(lambda: response.read(1024 * 1024), b""):
            output.write(block)
    if digest(temporary) != expected_digest:
        temporary.unlink()
        raise ValueError(f"SHA-256 mismatch for {name}")
    temporary.replace(destination)
    print(f"Verified {destination}")


def main():
    directory = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Models/Julia-1")
    directory.mkdir(parents=True, exist_ok=True)
    for name, expected_digest in FILES.items():
        download(directory, name, expected_digest)


if __name__ == "__main__":
    main()
