"""Plan and apply the ITE platform profile to a disposable bundle copy only."""

import argparse
import configparser
import json
import re
import shutil
import subprocess
from pathlib import Path


# Shared libraries may be used by ITE applications. Platform HALs and simulators
# are deliberately opt-in, so a new upstream vendor cannot silently enter a pack.
SHARED_PROJECTS = {
    "acpica", "dhara", "fatfs", "hostap", "liblc3", "libmctp", "libmetal",
    "libsbc", "littlefs", "lora-basics-modem", "loramac-node", "lvgl",
    "mbedtls", "mcuboot", "mipi-sys-t", "mldsa-native", "nanopb", "net-tools",
    "open-amp", "openthread", "percepio", "picolibc", "segger",
    "tf-psa-crypto", "tf-psa-crypto-drivers", "uoscore-uedhoc", "zcbor",
    "zephyr-lang-rust",
}

# Kconfig parses some other platforms unconditionally. Keep those small files,
# along with common drivers/bindings (including external peripheral vendors).
PLATFORM_ROOTS = {
    "boards": {"ite", "common", "shields"},
    "soc": {"ite", "common"},
    "arch": {"riscv", "common"},
    "dts": {"riscv", "common", "bindings"},
    "dts/riscv": {"ite"},
}


def within(path, parent):
    path = path.resolve()
    path.relative_to(parent.resolve())
    if path == parent.resolve():
        raise ValueError(f"Expected a child path: {path}")
    return path


def git(repo, *args, input=None):
    return subprocess.run(
        ["git", "-c", f"safe.directory={repo.as_posix()}", "-C", str(repo), *args],
        input=input, text=True, encoding="utf-8", check=True,
        stdout=subprocess.PIPE,
    ).stdout


def platform_exclusions(zephyr):
    excluded = []
    for relative, keep in PLATFORM_ROOTS.items():
        root = zephyr / relative
        if root.is_dir():
            excluded.extend(p for p in root.iterdir() if p.is_dir() and p.name not in keep)
    return sorted(excluded)


def sparse_patterns():
    # Rules describe directory roles, rather than today's vendor names, so new
    # vendor folders remain excluded after pull/switch as well.
    patterns = ["/*"]
    for root, keep in PLATFORM_ROOTS.items():
        patterns.append(f"!/{root}/*/")
        patterns.extend(f"/{root}/{name}/" for name in sorted(keep))
        patterns.append(f"/{root}/**/Kconfig*")
    return "\n".join(patterns) + "\n"


def plan(source, toolchain):
    from west.manifest import Manifest

    manifest = Manifest.from_topdir(source)
    if Path(manifest.projects[0].abspath).resolve() != source / "zephyr":
        raise ValueError("The ITE profile requires the manifest repository at zephyr/.")
    zephyr = source / "zephyr"
    if not (zephyr / "soc/ite").is_dir() or not (zephyr / "boards/ite").is_dir():
        raise ValueError("The ITE profile requires soc/ite and boards/ite (HWMv2).")
    selected = []
    excluded = []
    for project in manifest.projects[1:]:
        path = within(Path(project.abspath), source)
        if manifest.is_active(project) and (
            project.name in SHARED_PROJECTS or project.name == "hal_ite"
        ):
            selected.append(project)
        else:
            excluded.append(str(path))
    # Never trim or copy an SDK accidentally as part of the workspace itself.
    excluded.extend(str(p) for p in source.glob("zephyr-sdk-*") if p.is_dir())
    excluded.extend(str(p) for p in platform_exclusions(zephyr))
    names = sorted(p.name for p in selected)
    return {
        "Profile": "Ite", "Toolchain": toolchain,
        "Projects": names,
        "ProjectPaths": [str(zephyr)] + [p.abspath for p in selected],
        "ExcludedDirectories": excluded,
        "ProjectFilter": "-.*" + "".join(",+" + re.escape(name) for name in names),
    }


def apply_profile(source, destination, selection):
    zephyr = within(destination / "zephyr", destination)
    if not (zephyr / ".git").is_dir():
        raise ValueError("ITE bundle needs a standalone Zephyr Git repository.")
    # A copied absolute worktree setting would point Git back at the source.
    config = configparser.RawConfigParser(strict=False)
    config.read([zephyr / ".git/config", zephyr / ".git/config.worktree"], encoding="utf-8-sig")
    if config.has_option("core", "worktree"):
        raise ValueError("A repository with core.worktree cannot be relocated safely.")
    # Preserve local edits to Kconfig files that the broad directory copy skipped.
    for directory in platform_exclusions(source / "zephyr"):
        for path in directory.rglob("Kconfig*"):
            if path.is_file():
                target = within(destination / path.relative_to(source), destination)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
    info = zephyr / ".git/info"
    info.mkdir(exist_ok=True)
    (info / "sparse-checkout").write_text(sparse_patterns(), encoding="utf-8")
    git(zephyr, "config", "core.sparseCheckout", "true")
    git(zephyr, "config", "core.sparseCheckoutCone", "false")
    # Disable a source worktree-specific sparse configuration, if present.
    if (zephyr / ".git/config.worktree").is_file():
        git(zephyr, "config", "--worktree", "core.sparseCheckout", "true")
        git(zephyr, "config", "--worktree", "core.sparseCheckoutCone", "false")
    git(zephyr, "sparse-checkout", "reapply", "--no-cone", "--no-sparse-index")
    west_config = destination / ".west/config"
    config = configparser.RawConfigParser()
    config.read(west_config, encoding="utf-8-sig")
    config.set("manifest", "project-filter", selection["ProjectFilter"])
    with west_config.open("w", encoding="utf-8") as stream:
        config.write(stream)
    (destination / ".ite-bundle.json").write_text(
        json.dumps({"Profile": "Ite", "Projects": selection["Projects"],
                    "ProjectFilter": selection["ProjectFilter"]}, indent=2) + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--toolchain", default="riscv64-zephyr-elf")
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--selection", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    if args.destination:
        destination = args.destination.resolve()
        # Only a newly created packaging stage is a valid mutation target.
        if destination == source or source in destination.parents or destination in source.parents:
            raise ValueError("ITE profile must be applied to an independent staging copy.")
        selection = json.loads(args.selection.read_text(encoding="utf-8-sig"))
        apply_profile(source, destination, selection)
    else:
        print(json.dumps(plan(source, args.toolchain)))


if __name__ == "__main__":
    main()
