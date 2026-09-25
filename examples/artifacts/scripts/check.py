"""An ordinary unsandboxed task checks working-tree source, not an artifact."""

from pathlib import Path

message = Path("src/message.txt").read_bytes()
if not message or not message.endswith(b"\n"):
    raise SystemExit("src/message.txt must be nonempty and end with a newline")
print("source checked")
