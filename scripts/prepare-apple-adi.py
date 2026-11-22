"""Prepare the two ARM64 libraries from the user's local Apple Music APKs."""

import argparse
import os
from pathlib import Path
import tempfile
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile


LIBRARIES = ("libCoreADI.so", "libstoreservicescore.so")
LIBRARY_PATH = "lib/arm64-v8a/"
MAX_LIBRARY_SIZE = 16 * 1024 * 1024


def collect_libraries(apk_paths):
    libraries = {}
    for path in apk_paths:
        with ZipFile(path) as apk:
            for name in LIBRARIES:
                matches = [item for item in apk.infolist() if item.filename == LIBRARY_PATH + name]
                if not matches:
                    continue
                if len(matches) != 1 or not 64 <= matches[0].file_size <= MAX_LIBRARY_SIZE:
                    raise ValueError(f"{path.name} has an invalid entry for {name}.")
                data = apk.read(matches[0])
                if data[:6] != b"\x7fELF\x02\x01" or data[16:20] != b"\x03\x00\xb7\x00":
                    raise ValueError(f"{name} is not an ARM64 ELF shared library.")
                if name in libraries and libraries[name] != data:
                    raise ValueError("Use base and split APKs from the same Apple Music build.")
                libraries[name] = data

    missing = [name for name in LIBRARIES if name not in libraries]
    if missing:
        raise ValueError(f"Missing ARM64 entries: {', '.join(missing)}. Include the ARM64 split APK if needed.")
    return libraries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apple_music_apk", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, default=Path("AppleADI.zip"))
    args = parser.parse_args()
    output = args.output.resolve()
    temporary = None
    try:
        libraries = collect_libraries(args.apple_music_apk)
        if output.exists():
            raise ValueError(f"{output.name} already exists. Choose a new output path.")
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".AppleADI-", delete=False) as handle:
            temporary = Path(handle.name)
        with ZipFile(temporary, "w", compression=ZIP_DEFLATED) as archive:
            for name in LIBRARIES:
                archive.writestr(name, libraries[name])
        os.replace(temporary, output)
    except (BadZipFile, OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Prepared {output.name} for local Files import.")


if __name__ == "__main__":
    main()
