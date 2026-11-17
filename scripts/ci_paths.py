import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def classify_paths(paths):
    required = {"core": False, "apple": False, "windows": False}
    for path in paths:
        if path.lower().endswith((".md", ".log")):
            continue
        if path.startswith("core/"):
            required.update(core=True, apple=True, windows=True)
        elif path.startswith("apps/apple/"):
            required["apple"] = True
        elif path.startswith("apps/windows/"):
            required["windows"] = True
        else:
            required.update(core=True, apple=True, windows=True)
    return required


def main():
    baseline = os.environ.get("CI_BASE_SHA", "")
    if not baseline or set(baseline) == {"0"}:
        paths = ["scripts/ci_paths.py"]
    else:
        result = subprocess.run(
            ["git", "diff", "--name-only", "-z", baseline + "...HEAD"],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        paths = [path.decode("utf-8") for path in result.stdout.split(b"\0") if path]
    required = classify_paths(paths)
    print(json.dumps({"paths": paths, "required": required}, indent=2))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for name, value in required.items():
                output.write(f"{name}={str(value).lower()}\n")


if __name__ == "__main__":
    main()
