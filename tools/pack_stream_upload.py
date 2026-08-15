#!/usr/bin/env python3
"""Split a stream from stdin into chunks, uploading and deleting each in turn.

Exists because of disk, not elegance. The RuntimeRoot is ~16GB raw and still
several GB compressed, while a GitHub Actions runner has nowhere near enough
free space to hold the whole archive AND the source volume. Streaming means
peak usage is one chunk (~1.9GB), regardless of total size.

macOS `split` has no --filter (that's GNU split), so this does the same job:
read a fixed-size chunk, write it, upload it, delete it, repeat.

Chunks stay under GitHub's 2GB per-release-asset limit.

Usage:
  tar czf - RuntimeRoot | pack_stream_upload.py <tag> <prefix> [chunk_bytes]
"""
import hashlib
import os
import subprocess
import sys

DEFAULT_CHUNK = 1900 * 1024 * 1024  # under GitHub's 2GB asset cap


def upload(tag, path):
    # --repo explicitly: this runs from a scratch directory (the source tree
    # is a read-only mount), and gh otherwise infers the repo from the CWD's
    # git dir -- "fatal: not a git repository".
    # --clobber so re-runs replace a partial asset instead of erroring out.
    cmd = ["gh", "release", "upload", tag, path, "--clobber"]
    repo = os.environ.get("GITHUB_REPOSITORY")
    if repo:
        cmd += ["--repo", repo]
    subprocess.run(cmd, check=True)


def main():
    tag = sys.argv[1]
    prefix = sys.argv[2]
    chunk_size = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_CHUNK

    stdin = sys.stdin.buffer
    index = 0
    total = 0
    manifest = []

    while True:
        name = f"{prefix}.{index:03d}"
        written = 0
        digest = hashlib.sha256()
        with open(name, "wb") as out:
            while written < chunk_size:
                buf = stdin.read(min(8 * 1024 * 1024, chunk_size - written))
                if not buf:
                    break
                out.write(buf)
                digest.update(buf)
                written += len(buf)

        if written == 0:
            os.remove(name)
            break

        total += written
        manifest.append(f"{name} {written} {digest.hexdigest()}")
        print(f"[pack] {name}: {written} bytes (total {total})", flush=True)
        upload(tag, name)
        os.remove(name)  # free the space before reading the next chunk
        index += 1

        if written < chunk_size:
            break  # short read means end of stream

    with open("manifest.txt", "w") as f:
        f.write(f"chunks {index}\ntotal {total}\n")
        f.write("\n".join(manifest) + "\n")
    upload(tag, "manifest.txt")
    print(f"[pack] done: {index} chunks, {total} bytes", flush=True)


if __name__ == "__main__":
    main()
