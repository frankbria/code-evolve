"""Hold the evolution-cycle lock for as long as a parent process lives.

Usage: hold_lock.py <lock-file> <parent-pid> <status-file>

Takes a non-blocking kernel advisory lock (flock) on <lock-file> and writes "locked" or
"busy" to <status-file>. While it holds the lock it waits for <parent-pid> to exit. The
kernel releases the lock when this process ends, so a crashed cycle never leaves a stale
lock, and the engine's child processes never inherit the lock's file descriptor.
"""

import fcntl
import os
import sys
import time


def write_status(status_path: str, status: str) -> None:
    temporary_path = f"{status_path}.tmp"
    with open(temporary_path, "w") as status_file:
        status_file.write(status)
    os.replace(temporary_path, status_path)


def parent_is_alive(parent_pid: int) -> bool:
    try:
        os.kill(parent_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def main() -> None:
    lock_path, parent_pid, status_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    lock_handle = open(lock_path, "a")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status(status_path, "busy")
        return
    write_status(status_path, "locked")
    # shortcut: the lock follows the engine, not agents it spawned, so SIGKILLing only the
    # engine can let its orphaned agent overlap the next cycle (holding the lock for every
    # descendant would let one stray dev server block all future cycles). Also, a PID reused
    # within one poll second would hold the lock until that process exits. Upgrade to
    # process-group tracking if either is seen.
    while parent_is_alive(parent_pid):
        time.sleep(1)


if __name__ == "__main__":
    main()
