#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.0.3"
NAME = 'Example "blue" release'
TAG = f"v{VERSION}"
FILES = {
    "SHA256SUMS": b"fixture checksums\n",
    f"kai-{VERSION}-aarch64-linux.tar.gz": b"arm64\x00\xfffixture",
    f"kai-{VERSION}-x86_64-linux.tar.gz": b"x64\x00\xfefixture",
}


def run(args, cwd=None, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check, text=True, capture_output=True)


class Api:
    def __init__(self, fail_upload=0):
        self.release = None
        self.assets = []
        self.events = []
        self.fail_upload = fail_upload
        self.upload_count = 0
        self.next_asset = 1
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def body(self):
                return self.rfile.read(int(self.headers.get("Content-Length", "0")))

            def reply(self, status, value=None):
                data = b"" if value is None else json.dumps(value).encode()
                self.send_response(status)
                if data:
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def release_json(self):
                return {
                    "assets": api.assets,
                    "draft": api.release["draft"],
                    "id": 42,
                    "name": api.release["name"],
                    "prerelease": api.release.get("prerelease", False),
                    "tag_name": api.release.get("tag_name", TAG),
                    "upload_url": f"{api.url}/uploads/42/assets{{?name,label}}",
                }

            def authorized(self):
                return self.headers.get("Authorization") == "Bearer test-token"

            def do_GET(self):
                assert self.authorized()
                if self.path == "/repos/example-owner/example-repo":
                    self.reply(200, {"full_name": "example-owner/example-repo"})
                elif self.path == f"/repos/example-owner/example-repo/releases/tags/{TAG}":
                    self.reply(404 if api.release is None else 200, None if api.release is None else self.release_json())
                else:
                    self.reply(404)

            def do_POST(self):
                assert self.authorized()
                body = self.body()
                if self.path == "/repos/example-owner/example-repo/releases":
                    payload = json.loads(body)
                    api.events.append(("create", payload))
                    api.release = payload
                    api.release["draft"] = True
                    self.reply(201, self.release_json())
                    return
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == "/uploads/42/assets":
                    name = urllib.parse.parse_qs(parsed.query)["name"][0]
                    api.upload_count += 1
                    api.events.append(("upload", name, body))
                    if api.upload_count == api.fail_upload:
                        self.reply(500, {"message": "fixture interruption"})
                        return
                    asset = {
                        "digest": f"sha256:{hashlib.sha256(body).hexdigest()}",
                        "id": api.next_asset,
                        "name": name,
                        "state": "uploaded",
                    }
                    api.next_asset += 1
                    api.assets.append(asset)
                    self.reply(201, asset)
                    return
                self.reply(404)

            def do_DELETE(self):
                assert self.authorized()
                asset_id = int(self.path.rsplit("/", 1)[1])
                api.events.append(("delete", asset_id))
                api.assets = [asset for asset in api.assets if asset["id"] != asset_id]
                self.reply(204)

            def do_PATCH(self):
                assert self.authorized()
                payload = json.loads(self.body())
                api.events.append(("publish", payload))
                assert payload == {"draft": False}
                api.release["draft"] = False
                self.reply(200, self.release_json())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.thread.join()

    def set_release(self, name=NAME, draft=False):
        self.release = {"draft": draft, "name": name, "prerelease": False, "tag_name": TAG}
        self.assets = [
            {
                "digest": f"sha256:{hashlib.sha256(body).hexdigest()}",
                "id": index,
                "name": filename,
                "state": "uploaded",
            }
            for index, (filename, body) in enumerate(FILES.items(), 1)
        ]


class Fixture:
    def __init__(self, root, publisher, api):
        self.root = pathlib.Path(root)
        self.repo = self.root / "repository"
        self.remote = self.root / "remote.git"
        self.bin = self.root / "bin"
        self.bin.mkdir(parents=True)
        (self.repo / "xkai-bin").mkdir(parents=True)
        run(["git", "init", "--quiet", "--initial-branch=master"], self.repo)
        run(["git", "config", "user.name", "Release Test"], self.repo)
        run(["git", "config", "user.email", "release-test@example.invalid"], self.repo)
        (self.repo / "xkai-bin" / "VERSION").write_text(VERSION)
        (self.repo / "xkai-bin" / "RELEASE_NAME").write_text(NAME)
        (self.repo / "build.zig.zon").write_text(f'.{{\n    .name = .example,\n    .version = "{VERSION}",\n    .paths = .{{}},\n}}\n')
        (self.repo / ".gitignore").write_text("dist/\n")
        run(["git", "add", "."], self.repo)
        run(["git", "commit", "--quiet", "--no-gpg-sign", "-m", "test: release state"], self.repo)
        run(["git", "clone", "--quiet", "--bare", str(self.repo), str(self.remote)])
        run(["git", "remote", "add", "origin", "git@github.com:example-owner/example-repo.git"], self.repo)
        self.sha = run(["git", "rev-parse", "HEAD"], self.repo).stdout.strip()
        self.publisher = publisher
        self.api = api
        self._write_tools()
        home = self.root / "home"
        home.mkdir()
        self.env = os.environ.copy()
        self.env.update({
            "FAKE_GIT_REMOTE": str(self.remote),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_SSH_COMMAND": str(self.bin / "ssh"),
            "GIT_SSH_VARIANT": "ssh",
            "GITHUB_API_URL": api.url,
            "GITHUB_REPOSITORY": "example-owner/example-repo",
            "GITHUB_SHA": self.sha,
            "GITHUB_TOKEN": "test-token",
            "HOME": str(home),
            "PATH": f"{self.bin}:{self.env['PATH']}",
        })

    def _write_tools(self):
        ssh = self.bin / "ssh"
        ssh.write_text("""#!/usr/bin/env bash
set -euo pipefail
command_string="${@: -1}"
case "$command_string" in
  "git-upload-pack 'example-owner/example-repo.git'") exec git-upload-pack "$FAKE_GIT_REMOTE" ;;
  "git-receive-pack 'example-owner/example-repo.git'") exec git-receive-pack "$FAKE_GIT_REMOTE" ;;
  *) exit 2 ;;
esac
""")
        zig = self.bin / "zig"
        assignments = "\n".join(
            f"Path({str(filename)!r}).write_bytes({body!r})" for filename, body in FILES.items()
        )
        zig.write_text(f"""#!/usr/bin/env python3
import pathlib
import sys
assert sys.argv[1:] == ["build", "build-release"]
dist = pathlib.Path("dist")
dist.mkdir(exist_ok=True)
Path = lambda name: dist / name
{assignments}
""")
        ssh.chmod(0o755)
        zig.chmod(0o755)

    def publish(self, success=True):
        result = run([self.publisher], self.repo, self.env, check=False)
        if success and result.returncode:
            raise AssertionError(result.stderr + result.stdout)
        if not success and not result.returncode:
            raise AssertionError("publication unexpectedly succeeded")
        return result

    def push_tag(self, name):
        run(["git", "tag", "--annotate", "--cleanup=verbatim", "--message", name, TAG, self.sha], self.repo)
        run(["git", "push", "--quiet", str(self.remote), f"refs/tags/{TAG}:refs/tags/{TAG}"], self.repo)
        run(["git", "tag", "--delete", TAG], self.repo)


def assert_remote_tag(fixture, name=NAME):
    kind = run(["git", f"--git-dir={fixture.remote}", "cat-file", "-t", f"refs/tags/{TAG}"]).stdout.strip()
    message = run(["git", f"--git-dir={fixture.remote}", "for-each-ref", "--format=%(contents:subject)", f"refs/tags/{TAG}"]).stdout.rstrip("\n")
    target = run(["git", f"--git-dir={fixture.remote}", "rev-parse", f"refs/tags/{TAG}^{{commit}}"]).stdout.strip()
    assert (kind, message, target) == ("tag", name, fixture.sha)


def main():
    publisher = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="kai-publish-release-") as temp:
        root = pathlib.Path(temp)

        fresh_api = Api()
        try:
            fresh = Fixture(root / "fresh", publisher, fresh_api)
            fresh.publish()
            assert_remote_tag(fresh)
            assert fresh_api.release["draft"] is False
            assert {event[1]: event[2] for event in fresh_api.events if event[0] == "upload"} == FILES
            assert fresh_api.events[-1] == ("publish", {"draft": False})
            mutations = len(fresh_api.events)
            fresh.publish()
            assert len(fresh_api.events) == mutations
        finally:
            fresh_api.close()

        recovery_api = Api(fail_upload=2)
        try:
            recovery = Fixture(root / "recovery", publisher, recovery_api)
            recovery.publish(success=False)
            assert_remote_tag(recovery)
            assert recovery_api.release["draft"] is True
            assert not any(event[0] == "publish" for event in recovery_api.events)
            recovery.publish()
            assert recovery_api.release["draft"] is False
            assert any(event[0] == "delete" for event in recovery_api.events)
        finally:
            recovery_api.close()

        tag_api = Api()
        try:
            collision = Fixture(root / "tag-collision", publisher, tag_api)
            collision.push_tag("Wrong release name")
            collision.publish(success=False)
            assert not tag_api.events
        finally:
            tag_api.close()

        release_api = Api()
        try:
            collision = Fixture(root / "release-collision", publisher, release_api)
            collision.push_tag(NAME)
            release_api.set_release(name="Wrong release name")
            collision.publish(success=False)
            assert not release_api.events
        finally:
            release_api.close()

    print("Protected release publication integration tests passed.")


if __name__ == "__main__":
    main()
