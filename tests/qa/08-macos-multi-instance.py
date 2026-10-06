#!/usr/bin/env python3
"""Exercise LaunchServices reopen without Accessibility or keyboard automation."""

import ctypes
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid


libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
if libproc is not None:
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int


def processes(executable):
    # LaunchServices does not always use the full path as argv[0]. Query the
    # kernel's executable path rather than matching a truncated ps command line.
    if libproc is None:
        raise RuntimeError("Process inspection requires macOS")
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    result = {}
    path = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
    for line in output.splitlines():
        pid, ppid = map(int, line.split())
        if libproc.proc_pidpath(pid, path, len(path)) > 0:
            if Path(os.fsdecode(path.value)).resolve() == executable:
                result[pid] = ppid
    return result


def wait_for_count(executable, count):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        pids = processes(executable)
        if len(pids) == count:
            return set(pids)
        time.sleep(0.1)
    raise AssertionError(f"expected {count} instances, found {len(pids)}: {pids}")


def shell_children(pids):
    output = subprocess.check_output(
        ["ps", "-ww", "-axo", "pid=,ppid=,comm="], text=True
    )
    children = {}
    for line in output.splitlines():
        pid, ppid, command = line.strip().split(None, 2)
        shell = Path(command).name.lstrip("-")
        if int(ppid) in pids and shell in {"zsh", "fish", "bash", "sh", "dash"}:
            children[int(ppid)] = int(pid)
    return children


def check_shells(pids):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        children = shell_children(pids)
        if set(children) == pids:
            assert len(set(children.values())) == len(pids)
            return children
        time.sleep(0.1)
    raise AssertionError(f"each instance must own a shell: {children}")


def cleanup(executable):
    for pid in processes(executable):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while processes(executable) and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in processes(executable):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    if sys.platform != "darwin":
        raise SystemExit("This test requires a macOS desktop session")
    root = Path(__file__).resolve().parents[2]
    binary = Path(
        sys.argv[1] if len(sys.argv) > 1 else root / "zig-out/bin/zt"
    ).resolve()
    # An isolated bundle ID avoids reopening or terminating the user's own zt.
    # Spaces in the path also exercise launches without shell interpolation.
    with tempfile.TemporaryDirectory(prefix="zt multi instance ") as tmp:
        bundle = Path(tmp) / "zt.app"
        subprocess.run(
            ["sh", "tools/package-macos.sh", str(binary), str(bundle)],
            cwd=root,
            check=True,
        )
        info_path = bundle / "Contents/Info.plist"
        with info_path.open("rb") as file:
            info = plistlib.load(file)
        info["CFBundleIdentifier"] += ".qa." + uuid.uuid4().hex
        with info_path.open("wb") as file:
            plistlib.dump(info, file)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
        executable = (bundle / "Contents/MacOS/zt").resolve()
        launch_log = Path(tmp) / "launch stderr"
        try:
            marker = Path(tmp) / "command starts"
            command = 'printf "started\\n" >> "$1"; while :; do /bin/sleep 1; done'
            subprocess.run(
                ["open", "-n", "--stderr", str(launch_log), str(bundle),
                 "--args", "-e", "/bin/sh", "-c",
                 command, "zt-reopen-qa", str(marker)],
                check=True,
            )
            first = wait_for_count(executable, 1)
            check_shells(first)
            time.sleep(1)
            assert set(processes(executable)) == first, "initial launch duplicated itself"
            assert marker.read_text() == "started\n"

            subprocess.run(["open", str(bundle)], check=True)
            second = wait_for_count(executable, 2)
            assert first < second, "reopen replaced the original session"
            subprocess.run(["open", str(bundle)], check=True)
            third = wait_for_count(executable, 3)
            assert second < third, "a second reopen replaced an existing session"
            shells = check_shells(third)
            time.sleep(1)
            assert set(processes(executable)) == third, "reopen recursively launched instances"
            assert marker.read_text() == "started\n", "reopen replayed the original -e command"

            os.kill(next(iter(first)), signal.SIGTERM)
            remaining = wait_for_count(executable, 2)
            assert remaining == third - first, "closing one instance affected another"
            assert check_shells(remaining) == {pid: shells[pid] for pid in remaining}

            subprocess.run(["open", "-n", str(bundle)], check=True)
            explicit = wait_for_count(executable, 3)
            assert remaining < explicit, "open -n failed to create an independent instance"
            check_shells(explicit)
            print("PASS: initial launch, repeated reopen, fresh shells, independent close, open -n")
        except Exception:
            if launch_log.exists():
                print("Application stderr:\n" + launch_log.read_text(errors="replace")[-8192:], file=sys.stderr)
            raise
        finally:
            cleanup(executable)


if __name__ == "__main__":
    main()
