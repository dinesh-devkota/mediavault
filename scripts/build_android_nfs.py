"""Build the opt-in Android NFS JNI test libraries from the exact libnfs source."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


NDK_VERSION = "28.2.13676358"
LIBNFS_VERSION = "5.0.3"
ARCHIVE_NAME = f"libnfs-{LIBNFS_VERSION}.tar.gz"
ARCHIVE_SHA256 = "d945cb4f4c8f82ee1f3640893a168810f794a28e1010bb007ec5add345e9df3e"
ARCHIVE_URL = f"https://codeload.github.com/sahlberg/libnfs/tar.gz/refs/tags/libnfs-{LIBNFS_VERSION}"
ABIS = {
    "arm64-v8a": ("ELF64", "AArch64"),
    "x86_64": ("ELF64", "Advanced Micro Devices X86-64"),
    "armeabi-v7a": ("ELF32", "ARM"),
    "x86": ("ELF32", "Intel 80386"),
}
LIBRARIES = ("libnfs.so", "libmediavaultnfs.so")


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def readelf_tool(ndk):
    candidates = sorted((ndk / "toolchains/llvm/prebuilt").glob("*/bin/llvm-readelf"))
    if len(candidates) != 1:
        raise SystemExit("The Android NDK LLVM tools are missing or ambiguous.")
    return candidates[0]


def verify_binary(readelf, library, abi):
    output = run([readelf, "--file-header", "--program-headers", "--dynamic", "--wide", library],
                 stdout=subprocess.PIPE, text=True).stdout
    elf_class, machine = ABIS[abi]
    if not re.search(rf"Class:\s+{elf_class}\s*$", output, re.MULTILINE) or not re.search(
        rf"Machine:\s+{re.escape(machine)}\s*$", output, re.MULTILINE
    ):
        raise RuntimeError(f"{library.name} is not an Android {abi} ELF.")
    load_alignments = [int(alignment, 16) for alignment in re.findall(
        r"^\s*LOAD\s+[^\n]+\s+(0x[0-9a-fA-F]+)\s*$", output, re.MULTILINE
    )]
    expected_alignment = 0x4000 if elf_class == "ELF64" else 0x1000
    if not load_alignments or min(load_alignments) < expected_alignment:
        raise RuntimeError(f"{library.name} has insufficient ELF load alignment for {abi}.")
    if library.name == "libnfs.so" and not re.search(r"\(SONAME\).*\[libnfs\.so\]", output):
        raise RuntimeError("libnfs must use the unversioned Android SONAME.")
    if library.name == "libmediavaultnfs.so" and not re.search(r"\(NEEDED\).*\[libnfs\.so\]", output):
        raise RuntimeError("The JNI bridge must dynamically link to the separate libnfs.so.")


def prepare_source(work, archive):
    archive_path = work / ARCHIVE_NAME
    if archive is not None:
        shutil.copyfile(archive, archive_path)
    else:
        with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as source, archive_path.open("wb") as output:
            shutil.copyfileobj(source, output)
    with archive_path.open("rb") as archive_file:
        if hashlib.file_digest(archive_file, "sha256").hexdigest() != ARCHIVE_SHA256:
            raise RuntimeError("The libnfs source archive checksum did not match.")
    with tarfile.open(archive_path, "r:gz") as bundle:
        bundle.extractall(work, filter="data")
    source = work / f"libnfs-libnfs-{LIBNFS_VERSION}"
    if not (source / "COPYING").is_file():
        raise RuntimeError("The pinned libnfs source and licensing notice were not present.")
    return source, archive_path


def main():
    root = Path(__file__).resolve().parents[1]
    native = root / "android/native-nfs"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk", type=Path, required=True, help=f"Android NDK {NDK_VERSION} installation")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--abi", action="append", choices=ABIS, help="Defaults to all four Android ABIs")
    parser.add_argument("--source-archive", type=Path, help=f"Use a local copy of {ARCHIVE_NAME}")
    parser.add_argument("--cmake", default="cmake")
    options = parser.parse_args()

    ndk = options.ndk.resolve()
    properties = (ndk / "source.properties").read_text()
    if not re.search(rf"^Pkg\.Revision\s*=\s*{re.escape(NDK_VERSION)}\s*$", properties, re.MULTILINE):
        raise SystemExit(f"Use the pinned Android NDK {NDK_VERSION}.")
    readelf = readelf_tool(ndk)

    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit("Use an empty output directory to avoid mixing native builds.")

    with tempfile.TemporaryDirectory(prefix="mediavault-android-nfs-") as temporary:
        work = Path(temporary)
        source, archive = prepare_source(work, options.source_archive)
        run(["patch", "-p1", "--input", native / "nfs3-no-follow-opendir.patch"], cwd=source)
        for abi in options.abi or ABIS:
            build = work / f"build-{abi}"
            run([
                options.cmake, "-S", native, "-B", build, f"-DLIBNFS_SOURCE={source}",
                f"-DCMAKE_TOOLCHAIN_FILE={ndk / 'build/cmake/android.toolchain.cmake'}",
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release",
                f"-DANDROID_ABI={abi}", "-DANDROID_PLATFORM=android-26", "-DANDROID_STL=none",
            ])
            run([options.cmake, "--build", build, "--target", "mediavaultnfs", "--parallel", "2"])
            destination = work / "jniLibs" / abi
            destination.mkdir(parents=True)
            for name in LIBRARIES:
                binary = build / "libnfs/lib" / name if name == "libnfs.so" else build / name
                verify_binary(readelf, binary, abi)
                shutil.copyfile(binary, destination / name)
            print(f"Verified separate Android NFS and JNI libraries for {abi}.", flush=True)

        shutil.copytree(work / "jniLibs", output / "jniLibs")
        rebuild = output / "source"
        rebuild.mkdir()
        shutil.copyfile(archive, rebuild / ARCHIVE_NAME)
        shutil.copyfile(source / "COPYING", rebuild / "libnfs-COPYING")
        (rebuild / "scripts").mkdir()
        shutil.copyfile(Path(__file__), rebuild / "scripts/build_android_nfs.py")
        (rebuild / "android").mkdir()
        shutil.copytree(native, rebuild / "android/native-nfs")


if __name__ == "__main__":
    main()
