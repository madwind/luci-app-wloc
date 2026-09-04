#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
OPENWRT_VERSION = "25.12.5"
RUST_TOOLCHAIN = "1.89.0"
ZSTD_VERSION = "1.5.7"
ZSTD_SHA256 = "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"

TARGETS = {
    "mediatek/filogic": {
        "target": "mediatek",
        "subtarget": "filogic",
        "sdk_sha256": "ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25",
        "rust_target": "aarch64-unknown-linux-musl",
        "readelf_name": "aarch64-openwrt-linux-musl-readelf",
        "file_arch_pattern": r"ARM aarch64",
        "elf_machine_pattern": r"Machine:.*AArch64",
        "elf_interpreter": "/lib/ld-musl-aarch64.so.1",
        "apk_arch": "aarch64_cortex-a53",
        "target_mk_pattern": r"^SUBTARGET:=filogic$",
    },
    "rockchip/armv8": {
        "target": "rockchip",
        "subtarget": "armv8",
        "sdk_sha256": "59194a023968398af64bfa7d8bc3eac322641f6dc9cdbade28a4d9dd41866eba",
        "rust_target": "aarch64-unknown-linux-musl",
        "readelf_name": "aarch64-openwrt-linux-musl-readelf",
        "file_arch_pattern": r"ARM aarch64",
        "elf_machine_pattern": r"Machine:.*AArch64",
        "elf_interpreter": "/lib/ld-musl-aarch64.so.1",
        "apk_arch": "aarch64_generic",
        "target_mk_pattern": r"^SUBTARGET:=armv8$",
    },
    "x86/64": {
        "target": "x86",
        "subtarget": "64",
        "sdk_sha256": "0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c",
        "rust_target": "x86_64-unknown-linux-musl",
        "readelf_name": "x86_64-openwrt-linux-musl-readelf",
        "file_arch_pattern": r"x86-64",
        "elf_machine_pattern": r"Machine:.*X86-64",
        "elf_interpreter": "/lib/ld-musl-x86_64.so.1",
        "apk_arch": "x86_64",
        "target_mk_pattern": r"^ARCH:=x86_64$",
    },
}


def die(message: str) -> "NoReturn":
    print(message, file=sys.stderr)
    raise SystemExit(1)


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        die(detail or f"command failed ({result.returncode}): {' '.join(args)}")
    return result


def capture(args: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    return run(args, cwd=cwd, env=env, capture=True).stdout or ""


def require(command: str) -> None:
    if shutil.which(command) is None:
        die(f"missing build command: {command}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_sha256(path: Path, expected: str, label: str) -> None:
    if sha256(path).lower() != expected.lower():
        die(f"{label} checksum mismatch")


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    partial.unlink(missing_ok=True)
    run(["curl", "--fail", "--location", "--retry", "3", "--output", str(partial), url])
    partial.replace(destination)


def load_version() -> tuple[str, str]:
    values: dict[str, str] = {}
    for line in (PROJECT / "version.env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    version = values.get("WLOC_VERSION", "")
    release = values.get("WLOC_RELEASE", "")
    if not re.fullmatch(r"[A-Za-z0-9._+~-]+", version) or not re.fullmatch(r"[0-9]+", release):
        die("invalid version.env")
    return version, release


def first_path(root: Path, pattern: str) -> Path | None:
    for path in root.glob(pattern):
        return path
    return None


def first_recursive(root: Path, name: str) -> Path | None:
    for path in root.rglob(name):
        if path.is_file():
            return path
    return None


def ensure_zstd(cache_root: Path, download_dir: Path, env: dict[str, str]) -> None:
    if shutil.which("zstd", path=env.get("PATH")):
        return

    prefix = cache_root / "tools" / f"zstd-{ZSTD_VERSION}"
    archive = download_dir / f"zstd-{ZSTD_VERSION}.tar.gz"
    binary = prefix / "bin" / "zstd"
    if not binary.is_file():
        if not archive.is_file():
            download(
                f"https://github.com/facebook/zstd/releases/download/v{ZSTD_VERSION}/zstd-{ZSTD_VERSION}.tar.gz",
                archive,
            )
        verify_sha256(archive, ZSTD_SHA256, "zstd bootstrap")
        source = prefix / "source"
        shutil.rmtree(source, ignore_errors=True)
        source.mkdir(parents=True, exist_ok=True)
        binary.parent.mkdir(parents=True, exist_ok=True)
        run(["tar", "-xzf", str(archive), "-C", str(source), "--strip-components=1"])
        run(["make", "-C", str(source), f"-j{os.cpu_count() or 1}", "zstd-release"])
        shutil.copy2(source / "programs" / "zstd", binary)
        binary.chmod(0o755)

    env["PATH"] = f"{binary.parent}:{env.get('PATH', '')}"
    if shutil.which("zstd", path=env["PATH"]) is None:
        die("missing build command: zstd")


def find_sdk(extract_dir: Path) -> Path | None:
    candidates = sorted(
        path for path in extract_dir.glob(f"openwrt-sdk-{OPENWRT_VERSION}-*") if path.is_dir()
    )
    return candidates[0] if candidates else None


def verify_sdk(sdk_dir: Path, target: str, subtarget: str, target_mk_pattern: str) -> None:
    version_text = ""
    for path in (sdk_dir / "include" / "version.mk", sdk_dir / "version.buildinfo"):
        if path.is_file():
            version_text += path.read_text(encoding="utf-8", errors="replace")
    if OPENWRT_VERSION not in version_text:
        die(f"SDK is not OpenWrt {OPENWRT_VERSION}")
    if f"-{target}-{subtarget}_" not in sdk_dir.name:
        die(f"SDK target is not {target}/{subtarget}")
    target_mk = sdk_dir / "target" / "linux" / target / subtarget / "target.mk"
    if not target_mk.is_file() or re.search(
        target_mk_pattern,
        target_mk.read_text(encoding="utf-8", errors="replace"),
        re.MULTILINE,
    ) is None:
        die(f"SDK does not contain the {target}/{subtarget} subtarget")


def ensure_rust(rust_target: str, env: dict[str, str]) -> None:
    cargo_bin = Path.home() / ".cargo" / "bin"
    if shutil.which("rustup", path=env.get("PATH")) is None:
        print("Installing rustup in the current Linux user account")
        with tempfile.NamedTemporaryFile(prefix="rustup-", suffix=".sh", delete=False) as temp:
            installer = Path(temp.name)
        try:
            download("https://sh.rustup.rs", installer)
            run(
                ["sh", str(installer), "-y", "--profile", "minimal", "--default-toolchain", RUST_TOOLCHAIN],
                env=env,
            )
        finally:
            installer.unlink(missing_ok=True)
        env["PATH"] = f"{cargo_bin}:{env.get('PATH', '')}"

    require_path = shutil.which("rustup", path=env.get("PATH"))
    if require_path is None:
        die("rustup installation failed")
    run([require_path, "toolchain", "install", RUST_TOOLCHAIN, "--profile", "minimal"], env=env)
    run([require_path, "target", "add", "--toolchain", RUST_TOOLCHAIN, rust_target], env=env)
    env["RUSTUP_TOOLCHAIN"] = RUST_TOOLCHAIN
    cargo = shutil.which("cargo", path=env.get("PATH"))
    if cargo is None:
        die("cargo is unavailable after rustup setup")
    run([cargo, "fetch", "--locked"], cwd=PROJECT / "src" / "wloc-rs", env=env)


def copy_package_source(sdk_dir: Path) -> Path:
    destination = sdk_dir / "package" / "luci-app-wloc"
    if destination.parent != sdk_dir / "package":
        die("unsafe package destination")
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True, exist_ok=True)

    for name in ("Makefile", "version.env", "LICENSE", "NOTICE"):
        shutil.copy2(PROJECT / name, destination / name)

    (destination / "src" / "wloc-rs").mkdir(parents=True, exist_ok=True)
    shutil.copy2(PROJECT / "src" / "Makefile", destination / "src" / "Makefile")
    for name in ("Cargo.toml", "Cargo.lock"):
        shutil.copy2(PROJECT / "src" / "wloc-rs" / name, destination / "src" / "wloc-rs" / name)
    shutil.copytree(PROJECT / "src" / "wloc-rs" / "src", destination / "src" / "wloc-rs" / "src")
    shutil.copytree(PROJECT / "htdocs", destination / "htdocs")
    shutil.copytree(PROJECT / "root", destination / "root")
    if (PROJECT / "po").is_dir():
        shutil.copytree(PROJECT / "po", destination / "po")

    root = destination / "root"
    for path in root.rglob("*"):
        if path.is_dir():
            path.chmod(0o755)
        elif path.is_file():
            path.chmod(0o644)
    executable_paths = (
        "etc/init.d/wloc",
        "usr/libexec/wloc/ap.uc",
        "usr/libexec/wloc/firewall.uc",
        "usr/libexec/wloc/routing.uc",
        "usr/libexec/wloc/rules.uc",
        "usr/libexec/wloc/update.uc",
        "usr/libexec/wloc/wifi-schedule.uc",
    )
    for relative in executable_paths:
        path = root / relative
        if not path.is_file():
            die(f"missing runtime executable: {relative}")
        path.chmod(0o755)
    return destination


def set_package_selection(config: Path) -> None:
    lines = []
    if config.is_file():
        lines = [
            line
            for line in config.read_text(encoding="utf-8", errors="replace").splitlines()
            if not line.startswith("CONFIG_PACKAGE_luci-app-wloc=")
        ]
    lines.append("CONFIG_PACKAGE_luci-app-wloc=m")
    config.write_text("\n".join(lines) + "\n", encoding="utf-8")


def verify_sdk_config(config: Path, target: str, subtarget: str) -> None:
    text = config.read_text(encoding="utf-8", errors="replace")
    if f"CONFIG_TARGET_{target}=y" not in text or f"CONFIG_TARGET_{target}_{subtarget}=y" not in text:
        die(f"generated SDK config is not {target}/{subtarget}")
    if "CONFIG_PACKAGE_luci-app-wloc=m" not in text:
        die("luci-app-wloc is not selected in the SDK config")


def save_output(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    print(text, end="" if text.endswith("\n") else "\n")


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def executable_load_hash(readelf: str, elf: Path) -> str:
    output = capture([readelf, "-lW", str(elf)])
    offset = size = None
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[0] == "LOAD" and parts[6] == "R" and parts[7] == "E":
            try:
                offset = int(parts[1], 0) + 4096
                size = int(parts[4], 0) - 4096
            except ValueError:
                pass
            break
    if offset is None or size is None or size <= 0:
        die(f"unable to locate executable LOAD segment in {elf}")
    digest = hashlib.sha256()
    with elf.open("rb") as stream:
        stream.seek(offset)
        remaining = size
        while remaining > 0:
            block = stream.read(min(1024 * 1024, remaining))
            if not block:
                break
            digest.update(block)
            remaining -= len(block)
    if remaining != 0:
        die(f"unable to hash executable LOAD segment in {elf}")
    return digest.hexdigest()


def verify_package(
    sdk_dir: Path,
    apk: Path,
    dist_dir: Path,
    target_cfg: dict[str, str],
    package_version: str,
    package_release: str,
) -> None:
    readelf_path = first_recursive(sdk_dir / "staging_dir", target_cfg["readelf_name"])
    readelf = str(readelf_path) if readelf_path and os.access(readelf_path, os.X_OK) else "readelf"

    apk_tool = None
    for host_dir in sorted((sdk_dir / "staging_dir").glob("host*")):
        candidate = host_dir / "bin" / "apk"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            apk_tool = candidate
            break

    binary = None
    for candidate in (sdk_dir / "build_dir").rglob("wlocd"):
        if candidate.is_file() and "/.pkgdir/luci-app-wloc/usr/sbin/wlocd" in candidate.as_posix():
            binary = candidate
            break
    if binary is None:
        die("built wlocd was not found")

    print("Verifying ELF and package metadata")
    file_text = capture(["file", str(binary)])
    save_output(dist_dir / "wlocd.file.txt", file_text)
    if re.search(target_cfg["file_arch_pattern"], file_text) is None:
        die(f"wlocd is not {target_cfg['apk_arch']}")

    header = capture([readelf, "-h", str(binary)])
    save_output(dist_dir / "wlocd.elf-header.txt", header)
    if re.search(target_cfg["elf_machine_pattern"], header) is None:
        die(f"ELF machine is not {target_cfg['apk_arch']}")

    program_headers = capture([readelf, "-l", str(binary)])
    save_output(dist_dir / "wlocd.elf-program-headers.txt", program_headers)
    if target_cfg["elf_interpreter"] not in program_headers:
        die("ELF musl interpreter is incorrect")

    if apk_tool is None:
        die("SDK apk metadata tool not found")

    metadata = capture([str(apk_tool), "adbdump", str(apk)])
    save_output(dist_dir / "apk-metadata.txt", metadata)
    checks = (
        (rf"^\s*arch: {re.escape(target_cfg['apk_arch'])}$", f"APK metadata does not identify {target_cfg['apk_arch']}"),
        (r"^\s*name: luci-app-wloc$", "APK metadata has the wrong package name"),
        (rf"^\s*version: {re.escape(package_version)}-r{re.escape(package_release)}$", "APK metadata has the wrong package version"),
    )
    for pattern, message in checks:
        if re.search(pattern, metadata, re.MULTILINE) is None:
            die(message)

    with tempfile.TemporaryDirectory(prefix="wloc-apk-") as temp:
        extract_dir = Path(temp)
        run([str(apk_tool), "--allow-untrusted", "extract", str(apk)], cwd=extract_dir)
        files = sorted(path.relative_to(extract_dir).as_posix() for path in extract_dir.rglob("*") if path.is_file())
        (dist_dir / "apk-files.txt").write_text("\n".join(files) + "\n", encoding="utf-8")
        print("\n".join(files))

        packaged_wlocd = extract_dir / "usr" / "sbin" / "wlocd"
        packaged_file = capture(["file", str(packaged_wlocd)])
        if re.search(target_cfg["file_arch_pattern"], packaged_file) is None:
            die("APK contains a wlocd binary for the wrong architecture")

        elf_files: list[Path] = []
        for path in extract_dir.rglob("*"):
            if path.is_file() and "ELF" in capture(["file", str(path)]):
                elf_files.append(path)
        if elf_files != [packaged_wlocd]:
            die("APK contains an unexpected ELF file")
        if mode(packaged_wlocd) != 0o755:
            die("wlocd mode is not 0755")

        if executable_load_hash(readelf, binary) != executable_load_hash(readelf, packaged_wlocd):
            die("APK wlocd code does not match the binary built in this run")

        executable_paths = (
            "etc/init.d/wloc",
            "usr/libexec/wloc/ap.uc",
            "usr/libexec/wloc/firewall.uc",
            "usr/libexec/wloc/routing.uc",
            "usr/libexec/wloc/rules.uc",
            "usr/libexec/wloc/update.uc",
            "usr/libexec/wloc/wifi-schedule.uc",
        )
        for relative in executable_paths:
            path = extract_dir / relative
            if not path.is_file() or mode(path) != 0o755:
                die(f"{relative} mode is not 0755")

        data_paths = (
            "etc/config/wloc",
            "lib/upgrade/keep.d/luci-app-wloc",
            "usr/share/luci/menu.d/luci-app-wloc.json",
            "usr/share/rpcd/acl.d/luci-app-wloc.json",
            "usr/share/rpcd/ucode/luci.wloc.uc",
            "www/luci-static/resources/view/wloc/main.js",
        )
        for relative in data_paths:
            path = extract_dir / relative
            if not path.is_file() or mode(path) != 0o644:
                die(f"{relative} mode is not 0644")


def main() -> int:
    target_id = sys.argv[1] if len(sys.argv) > 1 else "mediatek/filogic"
    if len(sys.argv) > 2 or target_id not in TARGETS:
        print(f"usage: {Path(sys.argv[0]).name} {{mediatek/filogic|rockchip/armv8|x86/64}}", file=sys.stderr)
        return 2

    cfg = TARGETS[target_id]
    target = cfg["target"]
    subtarget = cfg["subtarget"]
    env = os.environ.copy()

    for command in ("curl", "tar", "make", "git", "file", "readelf", "stat"):
        require(command)
    if capture(["uname", "-m"]).strip() != "x86_64":
        die("the official SDK host requires Linux x86_64")

    default_cache = PROJECT / ".build" / f"openwrt-{OPENWRT_VERSION}" / target / subtarget
    cache_root = Path(env.get("OPENWRT_CACHE_ROOT", str(default_cache))).expanduser().resolve()
    if env.get("OPENWRT_BUILD_ROOT"):
        build_root = Path(env["OPENWRT_BUILD_ROOT"]).expanduser().resolve()
    else:
        filesystem = capture(["stat", "-f", "-c", "%T", str(PROJECT)]).strip()
        build_root = (
            Path.home() / ".cache" / "luci-app-wloc" / f"openwrt-{OPENWRT_VERSION}" / target / subtarget
            if filesystem == "v9fs"
            else cache_root
        )

    download_dir = cache_root / "downloads"
    extract_dir = build_root / "sdk"
    dist_dir = PROJECT / "dist" / target / subtarget
    sdk_file = f"openwrt-sdk-{OPENWRT_VERSION}-{target}-{subtarget}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
    sdk_url = f"https://downloads.openwrt.org/releases/{OPENWRT_VERSION}/targets/{target}/{subtarget}/{sdk_file}"
    archive = download_dir / sdk_file
    download_dir.mkdir(parents=True, exist_ok=True)
    extract_dir.mkdir(parents=True, exist_ok=True)
    dist_dir.mkdir(parents=True, exist_ok=True)

    ensure_zstd(cache_root, download_dir, env)
    if not archive.is_file():
        print(f"Downloading {sdk_file}")
        download(sdk_url, archive)
    verify_sha256(archive, cfg["sdk_sha256"], "SDK")

    sdk_dir = find_sdk(extract_dir)
    if sdk_dir is None:
        print("Extracting SDK")
        run(["tar", "--use-compress-program=zstd -d", "-xf", str(archive), "-C", str(extract_dir)], env=env)
        sdk_dir = find_sdk(extract_dir)
    if sdk_dir is None:
        die("SDK extraction failed")
    verify_sdk(sdk_dir, target, subtarget, cfg["target_mk_pattern"])

    ensure_rust(cfg["rust_target"], env)
    copy_package_source(sdk_dir)

    print("Installing LuCI package definitions")
    run(["./scripts/feeds", "update", "luci"], cwd=sdk_dir, env=env)
    run(["./scripts/feeds", "install", "luci-base"], cwd=sdk_dir, env=env)

    sdk_config = sdk_dir / ".config"
    sdk_config.touch()
    set_package_selection(sdk_config)
    print("Preparing OpenWrt SDK configuration")
    (sdk_dir / "staging_dir" / "host").mkdir(parents=True, exist_ok=True)
    (sdk_dir / "staging_dir" / "host" / ".prereq-build").touch()
    force_env = env.copy()
    force_env["FORCE"] = "1"
    run(["make", "-C", str(sdk_dir), "defconfig"], env=force_env)
    set_package_selection(sdk_config)
    verify_sdk_config(sdk_config, target, subtarget)

    package_version, package_release = load_version()
    expected_apk = f"luci-app-wloc-{package_version}-r{package_release}.apk"
    print("Building native OpenWrt APK v3 package")
    (sdk_dir / "bin").mkdir(parents=True, exist_ok=True)
    for old in (sdk_dir / "bin").rglob("luci-app-wloc-*.apk"):
        old.unlink()
    jobs = str(os.cpu_count() or 1)
    run([
        "make", "-C", str(sdk_dir), "CONFIG_PACKAGE_libc=y", "CONFIG_PACKAGE_libgcc=y",
        "package/toolchain/compile", f"-j{jobs}", "V=sc",
    ], env=env)
    run(["make", "-C", str(sdk_dir), "CONFIG_PACKAGE_luci-app-wloc=m", "package/luci-app-wloc/clean"], env=env)
    run([
        "make", "-C", str(sdk_dir), "CONFIG_PACKAGE_luci-app-wloc=m",
        "package/luci-app-wloc/compile", f"-j{jobs}", "V=sc",
    ], env=env)

    matches = [path for path in (sdk_dir / "bin").rglob(expected_apk) if path.is_file()]
    all_wloc_apks = [path for path in (sdk_dir / "bin").rglob("luci-app-wloc-*.apk") if path.is_file()]
    if len(matches) != 1:
        die(f"OpenWrt build did not produce exactly one {expected_apk}")
    if len(all_wloc_apks) != 1:
        die("OpenWrt build produced ambiguous WLOC APK artifacts")

    for old in dist_dir.glob("luci-app-wloc-*.apk*"):
        old.unlink()
    apk = dist_dir / expected_apk
    shutil.copy2(matches[0], apk)
    verify_package(sdk_dir, apk, dist_dir, cfg, package_version, package_release)

    checksum_line = f"{sha256(apk)}  {apk.name}\n"
    checksum_path = Path(str(apk) + ".sha256")
    checksum_path.write_text(checksum_line, encoding="utf-8")
    print(checksum_line, end="")
    print(f"READY: {apk}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
