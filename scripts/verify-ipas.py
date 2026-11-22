"""Verify the three unsigned Personal Signer device archives."""

from hashlib import sha256
from pathlib import Path
import plistlib
import struct
import sys
from zipfile import ZipFile


EXPECTED = {
    "PersonalSigner-proof-unsigned.ipa": ("PersonalSigner", "dev.kellen.personalsigner.proof", "1"),
    "StorageProbe-build-1-unsigned.ipa": ("StorageProbe", "dev.kellen.personalsigner.storageprobe", "1"),
    "StorageProbe-build-2-unsigned.ipa": ("StorageProbe", "dev.kellen.personalsigner.storageprobe", "2"),
}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def verify_executable(executable):
    header = executable.read(32)
    require(len(header) == 32, "truncated Mach-O header")
    magic, cpu_type, _, file_type, command_count, command_bytes, _, _ = struct.unpack("<8I", header)
    require(magic == 0xFEEDFACF and cpu_type == 0x0100000C and file_type == 2, "expected an arm64 Mach-O executable")
    require(command_bytes <= 1024 * 1024 and command_count <= command_bytes // 8, "invalid Mach-O load commands")
    commands = executable.read(command_bytes)
    require(len(commands) == command_bytes, "truncated Mach-O load commands")
    platform = None
    cursor = 0
    for _ in range(command_count):
        require(cursor + 8 <= len(commands), "truncated Mach-O command")
        kind, size = struct.unpack_from("<2I", commands, cursor)
        require(size >= 8 and cursor + size <= len(commands), "invalid Mach-O command length")
        if kind == 0x32:
            require(size >= 24, "invalid build version command")
            platform, = struct.unpack_from("<I", commands, cursor + 8)
        if kind in (0x21, 0x2C):
            require(size >= 20, "invalid encryption command")
            encryption, = struct.unpack_from("<I", commands, cursor + 16)
            require(encryption == 0, "encrypted executable")
        cursor += size
    require(cursor == command_bytes and platform == 2, "expected an iPhoneOS device build")


def verify_archive(path, product, bundle_id, build):
    app = f"Payload/{product}.app/"
    with ZipFile(path) as archive:
        require(archive.testzip() is None, "invalid IPA archive")
        paths = set(archive.namelist())
        require(
            {name.split("/")[1] for name in paths if name.startswith("Payload/") and name.count("/") > 1}
            == {product + ".app"},
            "expected one app in Payload",
        )
        require(app + "embedded.mobileprovision" not in paths, "embedded signing profile")
        require(app + "_CodeSignature/CodeResources" not in paths, "signed app resources")
        info = plistlib.loads(archive.read(app + "Info.plist"))
        require(info.get("CFBundleIdentifier") == bundle_id, "unexpected bundle identifier")
        require(info.get("CFBundleVersion") == build, "unexpected build number")
        require(info.get("CFBundleExecutable") == product, "unexpected executable name")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "expected iPhoneOS platform metadata")
        with archive.open(app + product) as executable:
            verify_executable(executable)


def main():
    output = Path(sys.argv[1])
    hashes = {}
    for line in (output / "SHA256SUMS").read_text().splitlines():
        digest, filename = line.split(maxsplit=1)
        hashes[Path(filename.lstrip("*")).name] = digest
    require(set(hashes) == set(EXPECTED), "checksums do not match the expected IPAs")
    for file, fields in EXPECTED.items():
        path = output / file
        verify_archive(path, *fields)
        checksum = sha256()
        with path.open("rb") as contents:
            for block in iter(lambda: contents.read(1024 * 1024), b""):
                checksum.update(block)
        digest = checksum.hexdigest()
        require(digest == hashes[file], f"checksum mismatch for {file}")
        print(f"{file}  {path.stat().st_size:,} bytes  {digest}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
