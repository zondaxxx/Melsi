#!/usr/bin/env python3
"""Hash native inputs before installing Go (including non-Go embedded assets).

The mobile library does not contain desktop commands or Go tests. Keep its
version/cache independent of those files, top-level docs, and app-only commits.
The Go package cache includes tests so changed tests can also be saved again.
"""

import argparse
import hashlib
import os
from pathlib import Path


def input_files(root: Path, kind: str) -> list[Path]:
    files = []
    core = root / "core"
    for directory, subdirs, names in os.walk(core):
        relative = Path(directory).relative_to(core)
        # Prune before walking: generated mobile trees contain the entire
        # sing-box module and must not slow hashing down or enter the key.
        subdirs[:] = [name for name in subdirs if name != ".git"]
        if relative == Path("."):
            excluded = {"dist", "docs"}
            if kind == "mobile":
                excluded.add("cmd")
            subdirs[:] = [name for name in subdirs if name not in excluded]
        if kind == "mobile" and relative == Path("tools"):
            subdirs[:] = [name for name in subdirs if name == "prepare-mobile"]
            continue
        for name in names:
            if relative == Path(".") and name in {"README.md", ".gitignore"}:
                continue
            if kind == "mobile" and name.endswith("_test.go"):
                continue
            # Include all other files, not only *.go: go:embed, assembly, and
            # platform-specific native inputs must invalidate the library too.
            files.append(Path(directory) / name)
    scripts = ["native-cache-key.py", "build-libbox.sh"]
    if kind == "go":
        scripts += ["build-core.sh", "go-build-settings.sh"]
    files.extend(root / "scripts" / name for name in scripts)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def source_hash(root: Path, kind: str) -> str:
    digest = hashlib.sha256()
    for path in input_files(root, kind):
        name = path.relative_to(root).as_posix().encode()
        content = path.read_bytes()
        for value in (name, content):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("mobile", "go"))
    args = parser.parse_args()
    print(source_hash(Path(__file__).resolve().parent.parent, args.kind))
