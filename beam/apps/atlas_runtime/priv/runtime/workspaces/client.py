"""Transport workspace operations to the launching Runtime executable."""
import array
import json
import os
import socket
import subprocess


def request(operation, *args, payload=None, pass_fds=()):
    executable = os.environ.get('ATLAS_RUNTIME_EXECUTABLE')
    if not executable:
        raise ValueError('Runtime workspace executable is unavailable')
    result = subprocess.run(
        [executable, 'workspace', operation, *(str(arg) for arg in args)],
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True, text=True, pass_fds=pass_fds)
    if result.returncode:
        raise ValueError(result.stderr.strip())
    return json.loads(result.stdout)


def acquire(workspace, create):
    received = array.array('i')
    parent, child = socket.socketpair()
    try:
        try:
            result = request('lock', workspace, json.dumps(create), child.fileno(),
                             pass_fds=(child.fileno(),))
        finally:
            child.close()
        _, ancillary, flags, _ = parent.recvmsg(1, socket.CMSG_SPACE(received.itemsize))
        for level, kind, data in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                received.frombytes(data)
        if flags & socket.MSG_CTRUNC or len(received) != 1:
            raise ValueError('Workspace helper did not return exactly one ownership descriptor')
        os.set_inheritable(received[0], False)
        return received[0], result['created']
    except BaseException:
        for descriptor in received:
            os.close(descriptor)
        raise
    finally:
        parent.close()
