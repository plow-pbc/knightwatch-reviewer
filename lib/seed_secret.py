#!/usr/bin/env python3
"""Atomically seed one secret below a trusted directory without symlink traversal."""
from __future__ import annotations

import os
import secrets
import stat
import sys
from pathlib import PurePosixPath


def seed_secret(source: str, root: str, relative: str) -> None:
    parts = PurePosixPath(relative).parts
    if not parts or PurePosixPath(relative).is_absolute() or any(
        part in ("", ".", "..") for part in parts
    ):
        raise ValueError(f"invalid relative secret path: {relative!r}")

    directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in parts[:-1]:
            try:
                os.mkdir(component, mode=0o755, dir_fd=directory_fd)
            except FileExistsError:
                pass
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd

        destination = parts[-1]
        try:
            existing = os.stat(destination, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if stat.S_ISLNK(existing.st_mode):
                os.unlink(destination, dir_fd=directory_fd)
            elif stat.S_ISREG(existing.st_mode):
                os.chmod(destination, 0o600, dir_fd=directory_fd, follow_symlinks=False)
            else:
                raise OSError(f"refusing non-file secret destination: {relative}")

        temporary = f".kwr-seed-{secrets.token_hex(8)}"
        temporary_fd = -1
        try:
            temporary_fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory_fd,
            )
            source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                while chunk := os.read(source_fd, 64 * 1024):
                    view = memoryview(chunk)
                    while view:
                        written = os.write(temporary_fd, view)
                        view = view[written:]
            finally:
                os.close(source_fd)
            os.fchmod(temporary_fd, 0o600)
            os.fsync(temporary_fd)
            os.close(temporary_fd)
            temporary_fd = -1
            os.replace(
                temporary,
                destination,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
        except BaseException:
            if temporary_fd >= 0:
                os.close(temporary_fd)
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(directory_fd)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: seed_secret.py SOURCE ROOT RELATIVE_PATH")
    seed_secret(*sys.argv[1:])
