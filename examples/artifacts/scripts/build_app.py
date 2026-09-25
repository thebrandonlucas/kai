"""Combine the locked assets Source with the declared library artifact."""

import os
from pathlib import Path

assets = Path(os.environ["KAI_INPUTS"]) / "assets"
library = Path(os.environ["KAI_ARTIFACTS"]) / "library"
# Both are read-only store paths, separate from this writable project copy.
Path("dist").mkdir()
Path("dist/app.txt").write_bytes(
    (assets / "heading.txt").read_bytes() + library.read_bytes()
)
