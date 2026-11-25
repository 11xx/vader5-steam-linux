#!/usr/bin/env python3
"""Isolated deployment tests. Run as a normal user: python3 tests/test_recovery.py."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRIMARY = "libSDL3.so.0"
ALIAS = "libSDL3.so"
STOCK = {PRIMARY: b"stock-primary".ljust(64, b"P"),
         ALIAS: b"stock-alias".ljust(48, b"A")}
PATCHED = b"patched-v1"


def digest(data):
    return hashlib.sha256(data).hexdigest()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="vader5-recovery-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "home with spaces"
        self.runtime = self.home / ".local/share/Steam/steamrt64"
        self.runtime.mkdir(parents=True)
        self.state = self.home / ".local/share/vader5-driver"
        self.backups = self.state / "backups/steamrt64"
        self.receipts = self.state / "deployed/steamrt64"
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        for name in ("install.sh", "uninstall.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.repo / "scripts" / name)
        # Fake a cached, already-patched Sniper build. Never fetch/build SDL.
        patch = b"fixture patch\n"
        (self.repo / "sdl-flydigi-vader5-linux.patch").write_bytes(patch)
        self.sdl = self.root / "sdl"
        (self.sdl / ".git").mkdir(parents=True)
        driver = self.sdl / "src/joystick/hidapi/SDL_hidapi_flydigi.c"
        driver.parent.mkdir(parents=True)
        driver.write_text("HIDAPI_DriverFlydigi_RumbleVader5Xpad\n")
        (self.sdl / ".vader5-patch.sha256").write_text(digest(patch) + "\n")
        self.built = self.sdl / "build-sniper64/libSDL3-stripped.so.0"
        self.built.parent.mkdir()
        self.built.write_bytes(PATCHED)
        for name, data in STOCK.items():
            (self.runtime / name).write_bytes(data)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(HOME=str(self.home), SDL_SRC=str(self.sdl),
                        PATH=str(self.bin) + os.pathsep + os.defpath,
                        LC_ALL="C", TMPDIR=str(self.root),
                        REAL_MV=shutil.which("mv", path=os.defpath),
                        STEAM_RUNTIME=str(self.runtime),
                        FORBIDDEN_LOG=str(self.root / "forbidden"))
        # Explicitly prevent system changes, real Steam probing and network/build work.
        forbidden = 'echo "$0 $*" >> "$FORBIDDEN_LOG"; exit 99\n'
        for cmd in ("sudo", "udevadm", "podman", "docker", "patch", "steam"):
            self.stub(cmd, forbidden)
        (self.repo / "tools").mkdir()
        firmware = self.repo / "tools/vader5-thirdparty.py"
        firmware.write_text("#!/bin/bash\n" + forbidden)
        firmware.chmod(0o755)
        self.stub("pgrep", "exit 1\n")
        self.stub("git", 'if [[ "$*" == *"rev-parse --short HEAD" ]]; then echo fixture; else ' + forbidden.rstrip() + '; fi\n')
        # Simulate only the build/ABI inputs; use real cp/mv/stat/sha256sum/padding.
        self.stub("readelf", """case "$1" in
  -h) echo 'Class: ELF64' ;;
  -d) printf '%s\\n' 'RUNPATH [$ORIGIN]' 'SONAME [libSDL3.so.0]' ;;
  *) exit 99 ;;
esac
""")
        self.stub("nm", 'if [[ "$*" == *--defined-only* && "$*" != *--undefined-only* ]]; then echo "0000 T SDL_Fixture"; fi\n')
        self.stub("mv", r'''src="${@: -2:1}"
dst="${@: -1}"
case "${FAIL_MODE:-}" in
  second-rename|rollback-failure)
    if [[ ( "$src" == */libSDL3.so.new || "$src" == */libSDL3.so.vader5-tmp ) && "$dst" == "$STEAM_RUNTIME/libSDL3.so" ]]; then exit 77; fi
    if [[ "$FAIL_MODE" == rollback-failure && "$src" == */libSDL3.so.0.original ]]; then exit 78; fi ;;
  receipt-publish)
    if [[ "$src" == */libSDL3.so.transition ]]; then exit 77; fi ;;
  receipt-finalize)
    if [[ "$src" == */libSDL3.so.0.final ]]; then exit 77; fi ;;
  kill-after-first)
    if [[ "$src" == */libSDL3.so.0.new ]]; then
        "$REAL_MV" "$@" || exit $?
        kill -KILL "$PPID"
        exit 0
    fi ;;
  restore-second)
    if [[ "$src" == *.vader5-restore.* && "$dst" == "$STEAM_RUNTIME/libSDL3.so" ]]; then exit 77; fi ;;
esac
exec "$REAL_MV" "$@"
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def run_script(self, name, *args, fail=None, success=True):
        env = dict(self.env)
        if fail:
            env["FAIL_MODE"] = fail
        result = subprocess.run(["bash", str(self.repo / "scripts" / name), *args],
                                env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=20)
        self.assertFalse((self.root / "forbidden").exists(), "system/build command invoked")
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def deploy(self, **kwargs):
        return self.run_script("install.sh", "--skip-udev", "--no-thirdparty", **kwargs)

    def uninstall(self, *args, **kwargs):
        return self.run_script("uninstall.sh", "--keep-udev", *args, **kwargs)

    def live(self):
        return {name: (self.runtime / name).read_bytes() for name in STOCK}

    def recovery(self):
        return {str(p.relative_to(self.state)): p.read_bytes()
                for folder in (self.backups, self.receipts)
                for p in folder.glob("libSDL3*") if p.is_file()}

    def assert_stock_backups(self, expected=STOCK):
        for name, data in expected.items():
            self.assertEqual((self.backups / name).read_bytes(), data)

    def assert_receipts(self, expected=None):
        for name, data in (expected or self.live()).items():
            self.assertEqual((self.receipts / (name + ".sha256")).read_text(), digest(data) + "\n")

    def assert_clean_stages(self):
        for folder in (self.runtime, self.backups, self.receipts):
            self.assertEqual(list(folder.glob(".vader5-deploy.*")), [])

    def test_missing_steam_retains_recovery_and_retry(self):
        self.deploy()
        before = self.recovery()
        steam = self.runtime.parent
        offline = steam.with_name("Steam-offline")
        steam.rename(offline)
        self.uninstall(success=False)
        self.assertEqual(self.recovery(), before)
        offline.rename(steam)
        self.uninstall()
        self.assertEqual(self.live(), STOCK)
        self.assertFalse(self.state.exists())

    def test_secondary_too_small_changes_neither_library(self):
        (self.runtime / ALIAS).write_bytes(b"tiny")
        before = self.live()
        self.deploy(success=False)
        self.assertEqual(self.live(), before)
        self.assertEqual(self.recovery(), {})
        self.assert_clean_stages()

    def test_second_rename_failure_rolls_back_and_retains_recovery(self):
        self.deploy(fail="second-rename", success=False)
        self.assertEqual(self.live(), STOCK)
        self.assert_stock_backups()
        self.assert_clean_stages()
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_second_rename_failure_during_reinstall_keeps_old_patched_hash(self):
        self.deploy()
        first = self.live()
        self.built.write_bytes(b"patched-v2")
        self.deploy(fail="second-rename", success=False)
        self.assertEqual(self.live(), first)
        self.assert_stock_backups()
        for name, data in first.items():
            self.assertIn(digest(data), (self.receipts / (name + ".sha256")).read_text().splitlines())
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_receipt_publication_failure_precedes_live_changes(self):
        self.deploy(fail="receipt-publish", success=False)
        self.assertEqual(self.live(), STOCK)
        self.assert_stock_backups()
        self.assert_clean_stages()
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_receipt_finalization_failure_leaves_both_recoverable(self):
        self.deploy()
        self.built.write_bytes(b"patched-v2")
        self.deploy(fail="receipt-finalize", success=False)
        self.assertTrue(all(data.startswith(b"patched-v2") for data in self.live().values()))
        self.assert_stock_backups()
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_uncatchable_interruption_during_reinstall_is_recoverable(self):
        self.deploy()
        first = self.live()
        self.built.write_bytes(b"patched-v2")
        self.deploy(fail="kill-after-first", success=False)
        self.assertTrue(self.live()[PRIMARY].startswith(b"patched-v2"))
        self.assertEqual(self.live()[ALIAS], first[ALIAS])
        self.assert_stock_backups()
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_rollback_failure_leaves_stock_and_receipts_for_uninstall(self):
        self.deploy(fail="rollback-failure", success=False)
        self.assertTrue(self.live()[PRIMARY].startswith(PATCHED))
        self.assertEqual(self.live()[ALIAS], STOCK[ALIAS])
        self.assert_stock_backups()
        self.assertTrue(list(self.runtime.glob(".vader5-deploy.*")))
        self.uninstall()
        self.assertEqual(self.live(), STOCK)

    def test_padding_receipts_reinstall_and_stock_restore(self):
        self.deploy()
        self.assertEqual(self.live(), {name: PATCHED.ljust(len(data), b"\0") for name, data in STOCK.items()})
        self.assert_stock_backups()
        self.assert_receipts()
        self.built.write_bytes(b"patched-v2")
        self.deploy()
        self.assert_stock_backups()
        self.assert_receipts()
        self.assert_clean_stages()
        self.uninstall()
        self.assertEqual(self.live(), STOCK)
        self.assertFalse(self.state.exists())

    def test_steam_update_preserved_and_reinstall_refreshes_backup(self):
        self.deploy()
        updated = {name: b"steam-update".ljust(len(data) + 5, b"U") for name, data in STOCK.items()}
        for name, data in updated.items():
            (self.runtime / name).write_bytes(data)
        self.uninstall()
        self.assertEqual(self.live(), updated)
        self.deploy()
        newer = {name: b"newer-steam".ljust(len(data) + 7, b"N") for name, data in STOCK.items()}
        for name, data in newer.items():
            (self.runtime / name).write_bytes(data)
        self.deploy()
        self.assert_stock_backups(newer)
        self.assert_receipts()
        self.uninstall()
        self.assertEqual(self.live(), newer)

    def test_force_restores_despite_update(self):
        self.deploy()
        (self.runtime / PRIMARY).write_bytes(b"steam-updated")
        self.uninstall("--force")
        self.assertEqual(self.live(), STOCK)

    def test_symlink_and_missing_alias_are_not_replaced(self):
        alias = self.runtime / ALIAS
        alias.unlink()
        alias.symlink_to(PRIMARY)
        self.deploy()
        self.assertTrue(alias.is_symlink())
        self.assertFalse((self.backups / ALIAS).exists())
        self.uninstall()
        self.assertTrue(alias.is_symlink())
        alias.unlink()
        self.deploy()
        self.assertFalse(alias.exists())
        self.uninstall()
        self.assertFalse(alias.exists())
        self.assertEqual((self.runtime / PRIMARY).read_bytes(), STOCK[PRIMARY])

    def test_missing_backup_with_receipt_is_not_discarded(self):
        self.deploy()
        (self.backups / PRIMARY).unlink()
        before = self.recovery()
        patched = self.live()
        self.uninstall(success=False)
        self.assertEqual(self.recovery(), before)
        self.deploy(success=False)
        self.assertEqual(self.live(), patched)
        self.assertEqual(self.recovery(), before)

    def test_missing_receipt_does_not_replace_stock_backup(self):
        self.deploy()
        (self.receipts / (PRIMARY + ".sha256")).unlink()
        before = self.recovery()
        self.deploy(success=False)
        self.assertEqual(self.recovery(), before)
        self.uninstall(success=False)
        self.assertEqual(self.recovery(), before)
        self.uninstall("--force")
        self.assertEqual(self.live(), STOCK)

    def test_invalid_receipt_preserved_until_explicit_force(self):
        self.deploy()
        (self.receipts / (PRIMARY + ".sha256")).write_text("partial-hash\n")
        before = self.recovery()
        patched = self.live()
        self.deploy(success=False)
        self.assertEqual(self.live(), patched)
        self.assertEqual(self.recovery(), before)
        self.uninstall(success=False)
        self.assertEqual(self.recovery(), before)
        self.uninstall("--force")
        self.assertEqual(self.live(), STOCK)

    def test_missing_steam_without_recovery_is_noop(self):
        shutil.rmtree(self.runtime.parent)
        self.uninstall()
        self.assertFalse(self.state.exists())

    def test_steam_update_replaces_alias_with_symlink(self):
        self.deploy()
        alias = self.runtime / ALIAS
        alias.unlink()
        alias.symlink_to(PRIMARY)
        self.uninstall()
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), STOCK[PRIMARY])

    def test_second_restore_failure_preserves_both_backups_for_retry(self):
        self.deploy()
        before = self.recovery()
        self.uninstall(fail="restore-second", success=False)
        self.assertEqual(self.recovery(), before)
        self.assertEqual(self.live()[PRIMARY], STOCK[PRIMARY])
        self.assertTrue(self.live()[ALIAS].startswith(PATCHED))
        self.uninstall()
        self.assertEqual(self.live(), STOCK)
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    if os.geteuid() == 0:
        raise SystemExit("Run as a non-root user (the production scripts reject root).")
    unittest.main(verbosity=2)
