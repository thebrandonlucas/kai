"""Build from the current project snapshot, not from a locked Source."""

from pathlib import Path

Path("dist").mkdir()
Path("dist/library.txt").write_bytes(
    Path("src/message.txt").read_bytes().upper()
)
