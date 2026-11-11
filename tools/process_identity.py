"""Process identity for the local Runtime node (tools/runtime.py, tools/runtime_process.py):
bounded PID parsing and the OS's own birth, owner and argv of a process. No signalling."""
import ctypes
import os
from pathlib import Path
import struct
import sys

# Supported macOS/Linux pid_t is a signed 32-bit int. Exclude reserved 0/1,
# preserving the inspector's existing policy, before any native conversion.
PID_MAX = (1 << 31) - 1


def validate_pid(pid):
    if type(pid) is not int or not 1 < pid <= PID_MAX:
        raise ValueError('PID outside supported positive pid_t domain')
    return pid


def parse_pid(record):
    if not isinstance(record, str):
        raise ValueError('PID record must be decimal text')
    digits = record.strip()
    # Bound before int(): works for arbitrary-size corrupt records on every
    # supported Python, without narrowing or interpreter digit-limit exceptions.
    if not 1 <= len(digits) <= 10 or not digits.isascii() or not digits.isdecimal():
        raise ValueError('PID record must be bounded ASCII decimal text')
    return validate_pid(int(digits, 10))


def process_state(pid):
    """Exact birth and OS terminal state; no argument parsing or signalling."""
    validate_pid(pid)
    if sys.platform == 'linux':
        proc = Path('/proc')/str(pid)
        fields = (proc/'stat').read_text().rsplit(')', 1)[1].split()
        return dict(pid=pid, start=[Path('/proc/sys/kernel/random/boot_id').read_text().strip(), fields[19]], uid=proc.stat().st_uid, terminal=fields[0] in ('Z', 'X'))
    if sys.platform != 'darwin':
        raise ValueError('process identity inspection unsupported on this OS')
    import errno
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    data = ctypes.create_string_buffer(136)
    ctypes.set_errno(0)
    if library.proc_pidinfo(pid, 3, 0, data, 136) != 136:
        if ctypes.get_errno() == errno.ESRCH:
            raise ProcessLookupError(errno.ESRCH, 'process no longer exists')
        raise ValueError('retained process state unavailable')
    if struct.unpack_from('=I', data.raw, 12)[0] != pid:
        raise ValueError('OS process PID does not match requested identity')
    return dict(pid=pid, start=list(struct.unpack_from('=QQ', data.raw, 120)), uid=struct.unpack_from('=I', data.raw, 20)[0], terminal=struct.unpack_from('=I', data.raw, 4)[0] == 5)


def process_identity(pid):
    """Read OS argv boundaries and process birth identity; never parse ps prose."""
    validate_pid(pid)
    if sys.platform == 'linux':
        proc = Path('/proc')/str(pid)
        def birth():
            # stat's parenthesized comm can contain spaces and parentheses.
            return (proc/'stat').read_text().rsplit(')', 1)[1].split()[19]
        start = birth()
        argv = [os.fsdecode(arg) for arg in (proc/'cmdline').read_bytes().rstrip(b'\0').split(b'\0')]
        result = dict(pid=pid, start=[Path('/proc/sys/kernel/random/boot_id').read_text().strip(), start], uid=proc.stat().st_uid, exe=str((proc/'exe').resolve(strict=True)), argv=argv)
        if birth() != start:
            raise ValueError('process changed during inspection')
        return result
    if sys.platform != 'darwin':
        raise ValueError('process identity inspection unsupported on this OS')
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libc = ctypes.CDLL(None, use_errno=True)
    libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    libproc.proc_pidinfo.restype = ctypes.c_int
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    libc.sysctl.restype = ctypes.c_int
    def birth():
        # SDK sys/proc_info.h: PROC_PIDTBSDINFO=3, proc_bsdinfo size 136.
        data = ctypes.create_string_buffer(136)
        if libproc.proc_pidinfo(pid, 3, 0, data, 136) != 136:
            raise ValueError('retained process unavailable')
        if struct.unpack_from('=I', data.raw, 12)[0] != pid:
            raise ValueError('OS process PID does not match requested identity')
        return list(struct.unpack_from('=QQ', data.raw, 120)), struct.unpack_from('=I', data.raw, 20)[0]
    start, uid = birth()
    # SDK sys/sysctl.h: CTL_KERN=1, KERN_PROCARGS2=49; argc + exec path + argv.
    data = ctypes.create_string_buffer(1_048_576)
    size = ctypes.c_size_t(len(data))
    mib = (ctypes.c_int * 3)(1, 49, pid)
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        raise ValueError('retained process arguments unavailable')
    raw = data.raw[:size.value]
    argc = struct.unpack_from('=i', raw)[0]
    offset = raw.index(b'\0', 4) + 1
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    argv = []
    for _ in range(argc):
        end = raw.index(b'\0', offset)
        argv.append(os.fsdecode(raw[offset:end]))
        offset = end + 1
    executable = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, executable, len(executable)) <= 0 or birth() != (start, uid):
        raise ValueError('retained process changed or unavailable')
    return dict(pid=pid, start=start, uid=uid, exe=str(Path(os.fsdecode(executable.value)).resolve()), argv=argv)
