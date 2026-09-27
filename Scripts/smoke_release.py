import json
import os
import pathlib
import platform
import stat
import subprocess
import sys
import tempfile
import zipfile


def main():
    archive = pathlib.Path(sys.argv[1]).resolve()
    model_directory = pathlib.Path(sys.argv[2]).resolve()
    reference = json.loads((model_directory / "parity-cases.json").read_text())[0]
    request = reference["request"]
    payload = {
        "state": request["state"],
        "questions": {
            "answer": {
                "type": "choice",
                "instructions": request["question"],
                "criteria": {str(index): value for index, value in enumerate(request["options"])},
            }
        },
    }
    with tempfile.TemporaryDirectory() as temporary_name:
        temporary = pathlib.Path(temporary_name)
        with zipfile.ZipFile(archive) as contents:
            contents.extractall(temporary)
        root = next(temporary.iterdir())
        executable = root / "bin" / ("julia.exe" if platform.system() == "Windows" else "julia")
        if platform.system() != "Windows":
            executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        if platform.system() == "Windows":
            environment["PATH"] = str(root / "lib") + os.pathsep + environment.get("PATH", "")
        elif platform.system() == "Linux":
            environment["LD_LIBRARY_PATH"] = str(root / "lib") + os.pathsep + environment.get("LD_LIBRARY_PATH", "")
        result = subprocess.run(
            [str(executable), "decide", "--input", "-", "--model-dir", str(model_directory)],
            input=json.dumps(payload), capture_output=True, text=True, env=environment,
        )
        if result.returncode:
            details = result.stderr
            if platform.system() == "Linux":
                details += subprocess.run(["ldd", str(executable)], capture_output=True, text=True, env=environment).stdout
            raise RuntimeError(details)
        answer = json.loads(result.stdout)["answers"]["answer"]
        expected = str(max(range(len(reference["pytorch_logits"])), key=reference["pytorch_logits"].__getitem__))
        if answer["choice"] != expected:
            raise ValueError(f"Release chose {answer['choice']} instead of {expected}")
        print(f"Verified {archive.name}: choice {answer['choice']}")


if __name__ == "__main__":
    main()
