import pathlib
import shutil
import sys

import onnx


def main():
    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    destination.mkdir(parents=True, exist_ok=True)
    model = onnx.load(source / "model.onnx", load_external_data=True)
    onnx.save_model(model, destination / "model.onnx", save_as_external_data=False)
    shutil.copyfile(source / "tokenizer.json", destination / "tokenizer.json")


if __name__ == "__main__":
    main()
