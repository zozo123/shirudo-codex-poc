#!/usr/bin/env python3
"""Disposable loopback npm registry for the Switchboard publish lab."""
import argparse
import base64
import binascii
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
from secrets import compare_digest, token_urlsafe
from urllib.parse import unquote, urlsplit

PACKAGE = "switchboard-demo-linter"
VERSION = "1.2.3"
MAX_PUBLISH_BYTES = 1_000_000
TARBALL = f"{PACKAGE}-{VERSION}.tgz"


def loopback_ipv4(value):
    address = IPv4Address(value)
    if not address.is_loopback:
        raise ValueError("Use an IPv4 loopback address for the disposable registry")
    return str(address)


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(value)


def init_project(project, registry, token_file):
    endpoint = urlsplit(registry)
    if (
        endpoint.scheme != "http"
        or endpoint.path not in ("", "/")
        or endpoint.username
        or endpoint.query
        or endpoint.fragment
        or not endpoint.port
    ):
        raise ValueError("Use a registry URL like http://127.0.0.1:4873")
    address = loopback_ipv4(endpoint.hostname)
    registry = f"http://{address}:{endpoint.port}/"
    project.mkdir(parents=True, exist_ok=True)
    package = {
        "name": PACKAGE,
        "version": VERSION,
        "description": "Disposable example package for the Switchboard lab",
        "main": "index.js",
        "files": ["index.js"],
        "license": "MIT",
        "publishConfig": {"registry": registry},
    }
    token = token_urlsafe(32)
    files = {
        "package.json": json.dumps(package, indent=2) + "\n",
        "index.js": "'use strict';\nmodule.exports = (line) => /[ \\t]+$/.test(line);\n",
        ".npmrc": (
            f"registry={registry}\n"
            f"//{address}:{endpoint.port}/:_authToken={token}\n"
            "audit=false\nfund=false\nupdate-notifier=false\n"
        ),
    }
    conflicts = [name for name in files if (project / name).exists()]
    if conflicts or token_file.exists():
        raise FileExistsError("Use a fresh project directory and token file")
    write_private(token_file, token)
    for name, contents in files.items():
        if name == ".npmrc":
            write_private(project / name, contents)
        else:
            (project / name).write_text(contents, encoding="utf-8")
    print(f"{PACKAGE}@{VERSION} fixture created at {project}")


class LabRegistry(HTTPServer):
    def __init__(self, address, token):
        super().__init__(address, RegistryHandler)
        self.token = token
        self.base_url = f"http://{self.server_address[0]}:{self.server_port}"
        self.metadata = None
        self.tarball = None
        self.publish_count = 0
        self.download_count = 0


class RegistryHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    @property
    def route(self):
        return unquote(urlsplit(self.path).path)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        return compare_digest(header.encode(), f"Bearer {self.server.token}".encode())

    def reply(self, status, payload, content_type="application/json"):
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode()
        # Never echo authorization headers, raw request bodies, or query strings.
        print(
            json.dumps({"method": self.command, "path": self.route, "status": status}),
            flush=True,
        )
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_GET(self):
        if self.route == "/-/ping":
            return self.reply(HTTPStatus.OK, {"ok": True})
        if self.route == "/-/whoami":
            if self.authorized():
                return self.reply(HTTPStatus.OK, {"username": "switchboard-lab"})
            return self.reply(HTTPStatus.UNAUTHORIZED, {"error": "Lab token required"})
        if self.route == "/_lab/state":
            return self.reply(
                HTTPStatus.OK,
                {
                    "package": PACKAGE,
                    "versions": [VERSION] if self.server.metadata else [],
                    "published": self.server.publish_count,
                    "downloads": self.server.download_count,
                },
            )
        if self.server.metadata:
            if self.route == f"/{PACKAGE}":
                return self.reply(HTTPStatus.OK, self.server.metadata)
            if self.route in (f"/{PACKAGE}/{VERSION}", f"/{PACKAGE}/latest"):
                return self.reply(HTTPStatus.OK, self.server.metadata["versions"][VERSION])
            if self.route == f"/{PACKAGE}/-/{TARBALL}":
                if self.command == "GET":
                    self.server.download_count += 1
                return self.reply(
                    HTTPStatus.OK, self.server.tarball, "application/octet-stream"
                )
        return self.reply(HTTPStatus.NOT_FOUND, {"error": "Not found in lab"})

    do_HEAD = do_GET

    def do_PUT(self):
        if self.route != f"/{PACKAGE}":
            return self.reply(HTTPStatus.FORBIDDEN, {"error": "Only the lab package is allowed"})
        if not self.authorized():
            return self.reply(HTTPStatus.UNAUTHORIZED, {"error": "Lab token required"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= MAX_PUBLISH_BYTES:
                return self.reply(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Invalid body size"})
            document = json.loads(self.rfile.read(length))
            package = document["versions"][VERSION]
            attachment = document["_attachments"][TARBALL]
            tarball = base64.b64decode(attachment["data"], validate=True)
            if (
                document.get("name") != PACKAGE
                or set(document["versions"]) != {VERSION}
                or package.get("name") != PACKAGE
                or package.get("version") != VERSION
                or len(tarball) != attachment["length"]
            ):
                raise ValueError("Unexpected name, version, or length")
        except (ValueError, TypeError, KeyError, AttributeError, binascii.Error):
            return self.reply(HTTPStatus.BAD_REQUEST, {"error": "Invalid lab publish document"})

        if self.server.metadata:
            return self.reply(HTTPStatus.CONFLICT, {"error": "Lab version already exists"})
        package["dist"] = {
            "shasum": hashlib.sha1(tarball).hexdigest(),
            "integrity": "sha512-" + base64.b64encode(hashlib.sha512(tarball).digest()).decode(),
            "tarball": f"{self.server.base_url}/{PACKAGE}/-/{TARBALL}",
        }
        self.server.metadata = {
            "_id": PACKAGE,
            "name": PACKAGE,
            "dist-tags": {"latest": VERSION},
            "versions": {VERSION: package},
        }
        self.server.tarball = tarball
        self.server.publish_count += 1
        return self.reply(HTTPStatus.CREATED, {"ok": True, "id": PACKAGE, "rev": "1-lab"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    init = operations.add_parser("init", help="write the publish fixture")
    init.add_argument("project", type=Path)
    init.add_argument("--registry", default="http://127.0.0.1:4873")
    init.add_argument("--token-file", type=Path, required=True)
    serve = operations.add_parser("serve", help="start a fresh in-memory registry")
    serve.add_argument("--bind", default="127.0.0.1", type=loopback_ipv4)
    serve.add_argument("--port", type=int, default=4873)
    serve.add_argument("--token-file", type=Path, required=True)
    args = parser.parse_args()
    if args.operation == "init":
        init_project(args.project, args.registry, args.token_file)
        return
    token = args.token_file.read_text(encoding="utf-8").strip()
    if not token:
        parser.error("Token file is empty")
    with LabRegistry((args.bind, args.port), token) as registry:
        print(json.dumps({"event": "ready", "registry": registry.base_url}), flush=True)
        registry.serve_forever()


if __name__ == "__main__":
    main()
