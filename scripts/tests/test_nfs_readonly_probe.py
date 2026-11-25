"""Run the linked NFS probe against a synthetic read-only NFSv3 export.

Usage: NFS_PROBE=/path/to/nfs_readonly_probe python3 -m unittest discover \
       -s scripts/tests -p test_nfs_readonly_probe.py
"""

import argparse
import os
import socketserver
import struct
import subprocess
import sys
import threading
import unittest
from collections import Counter
from dataclasses import dataclass

MOUNT = 100005
NFS = 100003
DIR = 2
FILE = 1
LINK = 5
FIXTURE_MEDIA = b"MediaVault fixture\n"


def words(*values):
    return struct.pack(f"!{len(values)}I", *values)


def uint64(value):
    return struct.pack("!Q", value)


def blob(value):
    return words(len(value)) + value + b"\0" * (-len(value) % 4)


class XDR:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, size):
        if self.pos + size > len(self.data):
            raise ValueError("short XDR argument")
        value = self.data[self.pos : self.pos + size]
        self.pos += size
        return value

    def uint(self):
        return struct.unpack("!I", self.take(4))[0]

    def uint64(self):
        return struct.unpack("!Q", self.take(8))[0]

    def blob(self):
        length = self.uint()
        return self.take((length + 3) & ~3)[:length]


@dataclass(frozen=True)
class Node:
    kind: int
    inode: int
    data: bytes = b""
    declared_size: int | None = None

    def attributes(self):
        size = len(self.data) if self.declared_size is None else self.declared_size
        mode = 0o555 if self.kind == DIR else 0o444
        return (
            words(self.kind, mode, 1, 1000, 1000)
            + uint64(size)
            + uint64(size)
            + words(0, 0)
            + uint64(1)
            + uint64(self.inode)
            + words(0, 0, 0, 0, 0, 0)
        )


class ReadOnlyExport(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, port=0, log_errors=False):
        super().__init__(("127.0.0.1", port), RPCHandler)
        self.nodes = {
            b"root": Node(DIR, 1),
            b"folder": Node(DIR, 2),
            b"movie": Node(FILE, 3, FIXTURE_MEDIA),
            b"nested": Node(FILE, 4, b"nested photo"),
            b"link": Node(LINK, 5, b"Movie.mp4"),
            b"truncated": Node(FILE, 6, b"head", declared_size=12),
            b"control": Node(FILE, 7),
            b"directoryLink": Node(LINK, 8, b"Photos"),
        }
        self.children = {
            b"root": {
                b"Movie.mp4": b"movie",
                b"Photos": b"folder",
                b"link.mp4": b"link",
                b"truncated.mp4": b"truncated",
                b"escape\x1b.mp4": b"control",
                b"PhotoAlias": b"directoryLink",
            },
            b"folder": {b"photo.jpg": b"nested"},
        }
        self.calls = Counter()
        self.errors = []
        self.log_errors = log_errors

    def dispatch(self, program, procedure, arguments):
        self.calls[program, procedure] += 1
        if procedure == 0:
            return b""
        if program == MOUNT:
            if procedure == 1 and arguments.blob() == b"/media":
                return words(0) + blob(b"root") + words(1, 1)
            raise ValueError(f"unexpected MOUNT procedure {procedure}")

        if program != NFS:
            raise ValueError(f"unexpected RPC program {program}")

        handle = arguments.blob()
        node = self.nodes[handle]
        attrs = words(1) + node.attributes()
        if procedure == 1:  # GETATTR
            return words(0) + node.attributes()
        if procedure == 3:  # LOOKUP
            target = self.children[handle].get(arguments.blob())
            if target is None:
                return words(2) + attrs  # NFS3ERR_NOENT
            return words(0) + blob(target) + words(1) + self.nodes[target].attributes() + attrs
        if procedure == 4:  # ACCESS
            mask = arguments.uint()
            if mask != 1:  # ACCESS3_READ
                raise ValueError(f"non-read ACCESS mask {mask}")
            return words(0) + attrs + words(mask)
        if procedure == 6:  # READ
            offset = arguments.uint64()
            count = arguments.uint()
            data = node.data[offset : offset + count]
            return words(0) + attrs + words(len(data), int(offset + len(data) >= len(node.data))) + blob(data)
        if procedure == 17:  # READDIRPLUS (the whole small directory fits in one response)
            if arguments.uint64() != 0:
                raise ValueError("unexpected directory continuation")
            entries = []
            for cookie, (name, target) in enumerate(self.children[handle].items(), 1):
                item = self.nodes[target]
                entries.append(
                    words(1) + uint64(item.inode) + blob(name) + uint64(cookie)
                    + words(1) + item.attributes() + words(1) + blob(target)
                )
            return words(0) + attrs + b"\0" * 8 + b"".join(entries) + words(0, 1)
        if procedure == 19:  # FSINFO
            return (
                words(0) + attrs + words(65536, 65536, 4096, 65536, 65536, 4096, 4096)
                + uint64(1 << 40) + words(0, 1, 8)
            )
        raise ValueError(f"unexpected NFS procedure {procedure}")


class RPCHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            while True:
                try:
                    marker = self.rfile.read(4)
                except ConnectionResetError:
                    # libnfs resets an idle socket when changing service or closing a context.
                    return
                if not marker:
                    return
                (record,) = struct.unpack("!I", marker)
                if not record & 0x80000000 or record & 0x7FFFFFFF > 65536:
                    raise ValueError("invalid RPC fixture record")
                reader = XDR(self.rfile.read(record & 0x7FFFFFFF))
                xid, message, rpc_version, program, version, procedure = struct.unpack("!6I", reader.take(24))
                if (message, rpc_version, version) != (0, 2, 3):
                    raise ValueError("unexpected RPC protocol version")
                for _ in range(2):
                    reader.uint()
                    reader.blob()
                data = self.server.dispatch(program, procedure, reader)
                reply = words(xid, 1, 0, 0, 0, 0) + data
                self.wfile.write(words(0x80000000 | len(reply)) + reply)
        except (OSError, ValueError, KeyError, struct.error) as error:
            self.server.errors.append(str(error))
            if self.server.log_errors:
                print(f"NFS fixture protocol error: {error}", file=sys.stderr, flush=True)


class NFSProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = os.environ.get("NFS_PROBE")
        if not cls.probe:
            raise unittest.SkipTest("NFS_PROBE must point to the linked native probe")

    def setUp(self):
        self.fixture = ReadOnlyExport()
        self.addCleanup(self.fixture.server_close)
        self.addCleanup(self.fixture.shutdown)
        threading.Thread(target=self.fixture.serve_forever, daemon=True).start()

    def run_probe(self, *args):
        port = str(self.fixture.server_address[1])
        result = subprocess.run(
            [self.probe, "--ports", port, port, "127.0.0.1", "/media", *args],
            capture_output=True,
            timeout=12,
            check=False,
        )
        self.assertEqual(self.fixture.errors, [], (result.stderr, self.fixture.calls))
        return result

    def test_lists_regular_files_and_folders_without_links_or_control_characters(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), {
            b"directory\t0\tPhotos",
            b"file\t19\tMovie.mp4",
            b"file\t12\ttruncated.mp4",
        })
        self.assertEqual(self.fixture.calls[NFS, 17], 1)

    def test_reads_exact_bytes_and_resolves_an_export_relative_nested_path(self):
        media = self.run_probe("Movie.mp4", "5", "7")
        photo = self.run_probe("Photos/photo.jpg", "7", "5")
        self.assertEqual(media.returncode, 0, media.stderr)
        self.assertEqual(media.stdout, FIXTURE_MEDIA[5:12])
        self.assertEqual(photo.returncode, 0, photo.stderr)
        self.assertEqual(photo.stdout, b"photo")
        self.assertEqual(self.fixture.calls[NFS, 6], 2)

    def test_rejects_unsafe_paths_and_invalid_ranges_without_contacting_export(self):
        for name, offset, length in (
            ("../Movie.mp4", "0", "1"),
            ("Photos//photo.jpg", "0", "1"),
            ("/Movie.mp4", "0", "1"),
            ("Movie.mp4", "0", "0"),
            ("Movie.mp4", "18446744073709551615", "1"),
            ("Movie.mp4", "0", "8388609"),
        ):
            with self.subTest(name=name, offset=offset, length=length):
                result = self.run_probe(name, offset, length)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
        self.assertEqual(self.fixture.calls, {})

    def test_does_not_follow_symlinks_or_fold_filename_case(self):
        for name in ("link.mp4", "link.mp4/photo.jpg", "movie.mp4"):
            result = self.run_probe(name, "0", "1")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
        self.assertEqual(self.fixture.calls[NFS, 5], 0)
        self.assertEqual(self.fixture.calls[NFS, 6], 0)

    def test_rejects_ranges_beyond_file_size_and_suppresses_truncated_reads(self):
        beyond = self.run_probe("Movie.mp4", "500", "1")
        truncated = self.run_probe("truncated.mp4", "0", "12")
        self.assertTrue(beyond.returncode)
        self.assertTrue(truncated.returncode)
        self.assertEqual(beyond.stdout, b"")
        self.assertEqual(truncated.stdout, b"")
        self.assertEqual(self.fixture.calls[NFS, 6], 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Serve the synthetic NFSv3 export on loopback.")
    parser.add_argument("--serve-port", type=int, required=True)
    args = parser.parse_args()
    with ReadOnlyExport(port=args.serve_port, log_errors=True) as server:
        print(f"NFS fixture listening on loopback port {server.server_address[1]}", flush=True)
        server.serve_forever()
