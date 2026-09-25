"""Sandbox runner: exact argv and one contained, symlink-free output."""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


def safe_tree(path):
    """Reject links and special files, including links in output ancestors."""
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise ValueError(
            f"symlink is not allowed in build output/source: {path}"
        )
    if stat.S_ISDIR(mode):
        for child in path.iterdir():
            safe_tree(child)
    elif not stat.S_ISREG(mode):
        raise ValueError(
            f"special file is not allowed in build output/source: {path}"
        )


def check_inputs(farm):
    """Allow generated farm links, not symlinks within fetched source trees."""
    for entry in Path(farm).iterdir():
        if not entry.is_symlink():
            raise ValueError(f"expected generated source link: {entry}")
        # Follow exactly the planner's farm link. safe_tree rejects a symlink
        # at the fetched root or anywhere beneath it, including remote inputs.
        safe_tree(entry.parent / os.readlink(entry))


def require_isolation(host):
    """Reject Run even when the daemon ignores client sandbox flags."""
    remedy = (
        "cannot verify build isolation; user Run was not executed. "
        "Enable sandbox = true and sandbox-fallback = false in the Nix "
        "daemon configuration and use a local Linux sandbox with /proc."
    )
    if not isinstance(host, dict) or set(host) != {"mnt", "net"}:
        raise ValueError(f"{remedy} Missing caller namespace observations.")
    for name in ("mnt", "net"):
        observed = host[name]
        if not isinstance(observed, str) or not re.fullmatch(
            rf"{name}:\[[0-9]+\]", observed
        ):
            raise ValueError(f"{remedy} Invalid caller {name} namespace.")
        try:
            current = os.readlink(f"/proc/self/ns/{name}")
        except OSError as error:
            raise ValueError(
                f"{remedy} Cannot read build {name} namespace: {error}"
            ) from error
        if not re.fullmatch(rf"{name}:\[[0-9]+\]", current):
            raise ValueError(f"{remedy} Invalid build {name} namespace.")
        if current == observed:
            raise ValueError(f"{remedy} Build shares caller {name} namespace.")


def main():
    spec = json.loads(Path(sys.argv[1]).read_text())
    require_isolation(spec.get("isolation"))
    source = Path(spec["project"])
    safe_tree(source)
    check_inputs(spec["inputs"])
    work = Path.cwd() / "blueprint-work"
    shutil.copytree(source, work)
    for path in [work, *work.rglob("*")]:
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    environment = os.environ.copy()
    environment.update(
        PATH=spec["path"],
        HOME=str(Path.cwd() / "blueprint-home"),
        BLUEPRINT_INPUTS=spec["inputs"],
        BLUEPRINT_ARTIFACTS=spec["artifacts"],
    )
    Path(environment["HOME"]).mkdir()
    result = subprocess.run(
        spec["argv"], cwd=work, env=environment, check=False
    )
    if result.returncode:
        code = result.returncode
        raise SystemExit(code if code > 0 else 128 - code)
    relative = Path(spec["output"])
    if relative.is_absolute() or not relative.parts or any(
        part in (".", "..") for part in relative.parts
    ):
        raise ValueError("invalid declared relative output")
    if work.is_symlink() or not work.is_dir():
        raise ValueError("build replaced the project workspace")
    output = work / relative
    for ancestor in [output, *output.parents]:
        if ancestor == work:
            break
        if ancestor.is_symlink():
            raise ValueError(f"symlink in declared output path: {ancestor}")
    if not output.exists():
        raise ValueError(f"declared output is missing: {spec['output']}")
    output.resolve().relative_to(work.resolve())
    safe_tree(output)
    destination = Path(os.environ["out"])
    if os.path.lexists(destination):
        raise ValueError(
            "build wrote directly to $out instead of declared Output"
        )
    if output.is_dir():
        shutil.copytree(output, destination)
    else:
        shutil.copy2(output, destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"blueprint build: {error}", file=sys.stderr)
        raise SystemExit(1)
