"""Offline integration checks for platform selection and subsequent Git updates.

Run with a Python environment containing west (the installed workspace venv).
"""

import importlib.util
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ite_bundle", ROOT / "scripts/ite-bundle.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


def write(root, name, text="fixture\n"):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class BundleTest(unittest.TestCase):
    def setUp(self):
        (ROOT / "offline_bundle").mkdir(exist_ok=True)
        self.fixture = Path(tempfile.mkdtemp(prefix="ite-test-", dir=ROOT / "offline_bundle")).resolve()
        self.source = self.fixture / "source"
        self.target = self.fixture / "bundle/zephyrproject"
        self.repo = self.source / "zephyr"
        write(self.source, ".west/config", "[manifest]\npath = zephyr\n")
        write(self.repo, "west.yml", f"""manifest:
  projects:
    - name: hal_ti
      url: https://example.invalid/hal_ti
      path: modules/hal/ti
    - name: hal_stm32
      url: https://example.invalid/hal_stm32
      path: modules/hal/stm32
    - name: littlefs
      url: '{(self.source / 'modules/fs/littlefs').as_posix()}'
      revision: main
      path: modules/fs/littlefs
  self:
    path: zephyr
""")
        for path in (
            "boards/ite/it51xxx_evb/board.yml", "boards/ite/it8xxx2_evb/board.yml",
            "boards/st/stm32/board.yml", "boards/newvendor/board.yml",
            "boards/st/common/Kconfig.qemu", "boards/common/board.cmake",
            "boards/shields/test/Kconfig.defconfig", "soc/ite/ec/soc.yml",
            "soc/common/common.c", "soc/ti/soc.yml", "soc/st/Kconfig.soc",
            "arch/riscv/core.c", "arch/arm/core.c", "arch/common/Kconfig",
            "dts/riscv/ite/it51xxx.dtsi", "dts/riscv/microchip/soc.dtsi",
            "dts/arm/st/soc.dtsi", "dts/bindings/sensor/st,sensor.yaml",
            "drivers/serial/uart_ns16550.c", "drivers/charger/charger_ti.c",
        ):
            write(self.repo, path)
        for path in ("modules/hal/ti/file.c", "modules/hal/stm32/file.c",
                     "modules/fs/littlefs/file.c", "app/user.c", "zephyr-sdk-1.0.1/sdk_version"):
            write(self.source, path)
        library = self.source / "modules/fs/littlefs"
        self.git("init", "-b", "main", repo=library)
        self.git("config", "user.email", "test@example.invalid", repo=library)
        self.git("config", "user.name", "Bundle Test", repo=library)
        self.git("add", ".", repo=library)
        self.git("commit", "-qm", "library", repo=library)
        self.git("init")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Bundle Test")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def tearDown(self):
        self.fixture.relative_to((ROOT / "offline_bundle").resolve())
        def writable_retry(function, path, error):
            Path(path).chmod(stat.S_IWRITE)
            function(path)
        shutil.rmtree(self.fixture, onexc=writable_retry)

    def git(self, *args, repo=None):
        return profile.git(repo or self.repo, *args)

    def pack(self):
        selection = profile.plan(self.source, "riscv64-zephyr-elf")
        excluded = {Path(p).resolve() for p in selection["ExcludedDirectories"]}
        shutil.copytree(self.source, self.target, ignore=lambda root, names: [
            name for name in names if (Path(root) / name).resolve() in excluded
        ])
        profile.apply_profile(self.source, self.target, selection)
        return selection

    def test_selection_and_local_edits(self):
        write(self.repo, "boards/ite/it51xxx_evb/local.c", "staged\n")
        self.git("add", ".")
        write(self.repo, "soc/st/Kconfig.soc", "local Kconfig edit\n")
        write(self.repo, "drivers/serial/uart_ns16550.c", "unstaged\n")
        before = self.git("status", "--porcelain")
        selection = self.pack()
        self.assertEqual(selection["Projects"], ["littlefs"])
        for path in ("modules/hal/ti", "modules/hal/stm32", "zephyr-sdk-1.0.1",
                     "zephyr/boards/st/stm32/board.yml", "zephyr/soc/ti/soc.yml",
                     "zephyr/arch/arm/core.c", "zephyr/dts/riscv/microchip/soc.dtsi"):
            self.assertFalse((self.target / path).exists(), path)
        self.assertTrue((self.target / "modules/fs/littlefs/file.c").is_file())
        self.assertTrue((self.target / "zephyr/drivers/charger/charger_ti.c").is_file())
        self.assertEqual((self.target / "zephyr/soc/st/Kconfig.soc").read_text(), "local Kconfig edit\n")
        self.assertEqual(self.git("status", "--porcelain", repo=self.target / "zephyr"), before)
        self.assertEqual(self.git("status", "--porcelain"), before)
        from west.manifest import Manifest
        manifest = Manifest.from_topdir(self.target)
        self.assertEqual([p.name for p in manifest.projects[1:] if manifest.is_active(p)], ["littlefs"])

    def test_fetch_and_merge_do_not_restore_other_platforms(self):
        self.pack()
        target_repo = self.target / "zephyr"
        self.git("remote", "add", "origin", self.repo.as_posix(), repo=target_repo)
        write(self.repo, "boards/st/stm32/board.yml", "updated ST\n")
        write(self.repo, "boards/futurevendor/new/board.yml")
        write(self.repo, "soc/futurevendor/soc.yml")
        write(self.repo, "dts/riscv/futurevendor/soc.dtsi")
        write(self.repo, "boards/ite/it51xxx_evb/new.c", "updated ITE\n")
        self.git("add", ".")
        self.git("commit", "-qm", "update both platforms")
        branch = self.git("branch", "--show-current").strip()
        self.git("fetch", "origin", repo=target_repo)
        self.git("merge", "--ff-only", f"origin/{branch}", repo=target_repo)
        self.assertTrue((target_repo / "boards/ite/it51xxx_evb/new.c").is_file())
        for name in ("boards/st/stm32/board.yml", "boards/futurevendor/new/board.yml",
                     "soc/futurevendor/soc.yml", "dts/riscv/futurevendor/soc.dtsi"):
            self.assertFalse((target_repo / name).exists(), name)
        self.assertEqual(self.git("status", "--porcelain", repo=target_repo), "")

    def test_west_update_only_updates_selected_modules(self):
        self.pack()
        result = subprocess.run([sys.executable, "-m", "west", "update"],
                                cwd=self.target, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.target / "modules/hal/ti").exists())
        self.assertFalse((self.target / "modules/hal/stm32").exists())
        self.assertEqual(self.git("rev-parse", "manifest-rev", repo=self.target / "modules/fs/littlefs").strip(),
                         self.git("rev-parse", "HEAD", repo=self.source / "modules/fs/littlefs").strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
