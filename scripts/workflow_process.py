"""Owned process trees with exclusive raw logs; no stdout/stderr pipes.

Windows uses a kill-on-close Job: create suspended, assign, then resume. POSIX
uses a new session/process group (deliberately daemonized/setsid children are
outside that contract). Cleanup is mandatory even after a normal parent exit.
Cleanup failure is fatal control flow, not an independently retryable test error.
"""
from contextlib import contextmanager
import math
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

CLEANUP_SECONDS = 10.0  # Existing cleanup allowance, NOT extra execution budget.
_POLL_SECONDS = 0.025
_poisoned = None


class ProcessCleanupError(BaseException):
    """Environment unsafe: do not catch as an ordinary per-case Exception."""


def _fatal(error):
    global _poisoned
    _poisoned = f"Process tree cleanup unverified: {type(error).__name__}: {error}"
    raise ProcessCleanupError(_poisoned) from error


@contextmanager
def _signals(*, defer=False):
    """Translate SIGTERM to cancellation; defer repeated signals during cleanup."""
    saved, pending = {}, []
    def handler(number, frame):
        if defer:
            pending.append(number)
        else:
            raise KeyboardInterrupt(f"Process execution cancelled by signal {number}")
    if threading.current_thread() is threading.main_thread():
        for number in (signal.SIGINT, signal.SIGTERM):
            saved[number] = signal.getsignal(number)
            signal.signal(number, handler)
    try:
        yield
    finally:
        for number, previous in saved.items():
            signal.signal(number, previous)
    if pending:
        raise KeyboardInterrupt(f"Process cleanup completed after signal {pending[0]}")


class _PosixTree:
    def __init__(self):
        self.process = None

    def start(self, args, stream, cwd):
        self.process = subprocess.Popen(args, cwd=cwd, stdin=subprocess.DEVNULL,
                                        stdout=stream, stderr=subprocess.STDOUT,
                                        start_new_session=True)
        self.pid = self.process.pid

    def poll(self):
        return self.process.poll()

    def cleanup(self):
        if self.process is None:
            return
        deadline = time.monotonic() + CLEANUP_SECONDS
        try:
            os.killpg(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=max(0.001, deadline - time.monotonic()))
        # killpg success is only a request, not proof that the group is gone.
        while True:
            try:
                os.killpg(self.pid, 0)
            except ProcessLookupError:
                return
            if time.monotonic() >= deadline:
                raise TimeoutError("POSIX process group still exists after SIGKILL")
            time.sleep(_POLL_SECONDS)

    def close(self):
        pass


if os.name == "nt":
    import ctypes
    from ctypes import wintypes as wt
    import _winapi
    import msvcrt

    class _BasicLimits(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                    ("flags", wt.DWORD), ("min_working_set", ctypes.c_size_t),
                    ("max_working_set", ctypes.c_size_t), ("active_limit", wt.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wt.DWORD),
                    ("scheduling", wt.DWORD)]

    class _IOCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in
                    ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

    class _ExtendedLimits(ctypes.Structure):
        _fields_ = [("basic", _BasicLimits), ("io", _IOCounters),
                    ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                    ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t)]

    class _Accounting(ctypes.Structure):
        _fields_ = [("user_time", ctypes.c_int64), ("kernel_time", ctypes.c_int64),
                    ("period_user", ctypes.c_int64), ("period_kernel", ctypes.c_int64),
                    ("page_faults", wt.DWORD), ("total", wt.DWORD),
                    ("active", wt.DWORD), ("terminated", wt.DWORD)]

    _kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    for _name, _arguments, _result in (
        ("CreateJobObjectW", [ctypes.c_void_p, wt.LPCWSTR], wt.HANDLE),
        ("SetInformationJobObject", [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD], wt.BOOL),
        ("QueryInformationJobObject", [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD, ctypes.c_void_p], wt.BOOL),
        ("AssignProcessToJobObject", [wt.HANDLE, wt.HANDLE], wt.BOOL),
        ("TerminateJobObject", [wt.HANDLE, wt.UINT], wt.BOOL),
        ("ResumeThread", [wt.HANDLE], wt.DWORD),
        ("CloseHandle", [wt.HANDLE], wt.BOOL),
    ):
        _function = getattr(_kernel, _name)
        _function.argtypes, _function.restype = _arguments, _result

    def _checked(result):
        if not result:
            raise ctypes.WinError(ctypes.get_last_error())
        return result

    class _WindowsTree:
        def __init__(self):
            self.job = self.handle = self.thread = None
            self.assigned = False
            self.returncode = None
            self.job = _checked(_kernel.CreateJobObjectW(None, None))
            try:
                limits = _ExtendedLimits()
                limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
                _checked(_kernel.SetInformationJobObject(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
            except BaseException:
                self.close()
                raise

        def start(self, args, stream, cwd):
            # CPython's Windows CreateProcess wrapper supports STARTUPINFOEX's
            # explicit handle list. No shell, stdin gate, stdout pipe or assign race.
            current = _winapi.GetCurrentProcess()
            inherited = []
            try:
                with open(os.devnull, "rb") as null:
                    for file in (null, stream):
                        inherited.append(_winapi.DuplicateHandle(
                            current, msvcrt.get_osfhandle(file.fileno()), current,
                            0, True, _winapi.DUPLICATE_SAME_ACCESS))
                    startup = subprocess.STARTUPINFO()
                    startup.dwFlags = subprocess.STARTF_USESTDHANDLES
                    startup.hStdInput, startup.hStdOutput = inherited
                    startup.hStdError = startup.hStdOutput
                    startup.lpAttributeList = {"handle_list": inherited}
                    self.handle, self.thread, self.pid, _ = _winapi.CreateProcess(
                        None, subprocess.list2cmdline([os.fspath(arg) for arg in args]),
                        None, None, True,
                        0x00000004 | 0x00000200 | 0x00080000,  # suspended, new group, extended startup
                        None, os.fspath(cwd), startup)
                _checked(_kernel.AssignProcessToJobObject(self.job, self.handle))
                self.assigned = True
                if _kernel.ResumeThread(self.thread) == 0xFFFFFFFF:
                    raise ctypes.WinError(ctypes.get_last_error())
            finally:
                for handle in inherited:
                    _winapi.CloseHandle(handle)

        def poll(self):
            if self.returncode is not None:
                return self.returncode
            status = _winapi.WaitForSingleObject(self.handle, 0)
            if status == _winapi.WAIT_TIMEOUT:
                return None
            if status != _winapi.WAIT_OBJECT_0:
                raise OSError(f"Unexpected process wait status: {status}")
            self.returncode = _winapi.GetExitCodeProcess(self.handle)
            return self.returncode

        def cleanup(self):
            if self.handle is None:
                return
            deadline = time.monotonic() + CLEANUP_SECONDS
            if self.assigned:
                _checked(_kernel.TerminateJobObject(self.job, 1))
            elif self.poll() is None:
                # Assignment failed: the still-suspended process cannot have children.
                _winapi.TerminateProcess(self.handle, 1)
            while True:
                accounting = _Accounting()
                _checked(_kernel.QueryInformationJobObject(
                    self.job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None))
                if accounting.active == 0 and self.poll() is not None:
                    return
                if time.monotonic() >= deadline:
                    raise TimeoutError("Windows Job still has active processes")
                time.sleep(_POLL_SECONDS)

        def close(self):
            for name in ("thread", "handle", "job"):
                handle = getattr(self, name)
                if handle is not None:
                    _checked(_kernel.CloseHandle(handle))
                    setattr(self, name, None)


def _new_tree():
    if os.name == "nt":
        return _WindowsTree()
    if os.name == "posix":
        return _PosixTree()
    raise OSError("Unsupported process-tree platform")


class _LogTail:
    """Bounded nonblocking regular-file observations; raw log is never rewritten."""
    def __init__(self, path, callback):
        self.stream = path.open("rb")
        self.callback = callback
        self.pending = b""

    def read(self, *, final=False):
        block = self.stream.read(65536)
        self.pending += block
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            self.callback((line + b"\n").decode("utf-8", errors="replace"))
        # Observation is non-gate: don't accumulate an unbounded unterminated line.
        if len(self.pending) > 65536 or (final and self.pending):
            self.callback(self.pending.decode("utf-8", errors="replace"))
            self.pending = b""
        return bool(block)

    def close(self):
        self.stream.close()


def _run_logged(args, path, timeout_seconds, *, cwd, on_start=None, on_line=None):
    if _poisoned is not None:
        raise ProcessCleanupError(_poisoned)
    if not math.isfinite(timeout_seconds) or timeout_seconds < 0:
        raise ValueError("timeout_seconds must be finite and nonnegative")
    path = Path(path)
    timed_out, code, tail, finished = False, None, None, False
    # Exclusive creation precedes process creation: collisions never launch work.
    with path.open("xb", buffering=0) as stream, _signals():
        tree = None
        try:
            # Do not interrupt the suspended-create/assign sequence between handles.
            with _signals(defer=True):
                tree = _new_tree()
                tree.start(args, stream, cwd)
            deadline = time.monotonic() + timeout_seconds
            if on_line is not None:
                tail = _LogTail(path, on_line)
            if on_start is not None:
                on_start(tree, deadline)
            while True:
                code = tree.poll()
                if code is not None:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                if tail is not None:
                    tail.read()
                time.sleep(min(_POLL_SECONDS, remaining))
            finished = True
        finally:
            # Even normal exit can leave children holding log/pipe handles. Do not
            # return, close the Job, or allow an independent case before zero active.
            with _signals(defer=True):
                try:
                    if tree is not None:
                        tree.cleanup()
                        if code is None and hasattr(tree, "pid"):
                            code = tree.poll()
                except BaseException as error:
                    _fatal(error)
                finally:
                    try:
                        if tree is not None:
                            tree.close()
                    except BaseException as error:
                        _fatal(error)
                    finally:
                        if tail is not None:
                            try:
                                # Final bounded observation catches short-lived commands;
                                # raw artifacts, not observer line counts, are authoritative.
                                if finished and _poisoned is None:
                                    tail.read(final=True)
                            finally:
                                tail.close()
    return code, timed_out


def run_logged(args, path, timeout_seconds, *, cwd):
    """Return (native exit code, outer timeout). Cancellation/fatal cleanup raise.

    Owns a fresh exclusive binary log. An existing path is never truncated.
    SIGINT/SIGTERM on the main thread propagate as KeyboardInterrupt after cleanup.
    Ordinary spawn errors propagate; cleanup errors poison subsequent invocations.
    """
    return _run_logged(args, path, timeout_seconds, cwd=cwd)


def run_logged_observed(args, path, timeout_seconds, *, cwd, on_start, on_line):
    """Legacy observer adapter; same containment and budgets as run_logged."""
    return _run_logged(args, path, timeout_seconds, cwd=cwd,
                       on_start=on_start, on_line=on_line)
