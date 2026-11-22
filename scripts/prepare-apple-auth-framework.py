"""Namespace AppleAuth's static XCFramework headers for Xcode."""

from pathlib import Path
import plistlib
import sys


def prepare(xcframework: Path) -> None:
    info_path = xcframework / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    for library in info["AvailableLibraries"]:
        if library["LibraryPath"] == "apple_auth.framework":
            continue
        if library["LibraryPath"] != "libapple_auth.a" or library["HeadersPath"] != "Headers":
            raise ValueError("Unexpected AppleAuth XCFramework slice layout")

        source = xcframework / library["LibraryIdentifier"]
        framework = source / "apple_auth.framework"
        framework.mkdir()
        (source / "libapple_auth.a").rename(framework / "apple_auth")
        (source / "Headers").rename(framework / "Headers")
        modules = framework / "Modules"
        modules.mkdir()
        old_map = framework / "Headers" / "module.modulemap"
        module = old_map.read_text()
        if not module.startswith("module apple_auth {"):
            raise ValueError("Unexpected AppleAuth module name")
        (modules / "module.modulemap").write_text("framework " + module)
        old_map.unlink()
        (framework / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "apple_auth",
            "CFBundleIdentifier": "dev.kellen.personalsigner.apple-auth",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "apple_auth",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "0.1.3",
            "CFBundleVersion": "1",
        }))
        library["LibraryPath"] = "apple_auth.framework"
        library["BinaryPath"] = "apple_auth.framework/apple_auth"
        del library["HeadersPath"]
    info_path.write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    prepare(Path(sys.argv[1]))
