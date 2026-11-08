import json
import os
import select
import time


def emit(event):
    print(json.dumps(event), flush=True)


def json_record(line, limit):
    if len(line) > limit:
        raise ValueError('Native protocol record exceeds its size limit')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    value = json.loads(line, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError('Native protocol record must be an object')
    return value


def write_native(stream, event):
    data = (json.dumps(event) + '\n').encode()
    if len(data) > 1048576:
        raise ValueError('Native input exceeds 1 MiB')
    remaining = memoryview(data)
    deadline = time.monotonic() + 3
    while remaining:
        timeout = deadline - time.monotonic()
        if timeout <= 0 or not select.select([], [stream], [], timeout)[1]:
            raise ValueError('Native input transport stalled')
        try:
            written = os.write(stream.fileno(), remaining)
        except BlockingIOError:
            continue
        except OSError as error:
            raise ValueError('Native input transport closed') from error
        if not written:
            raise ValueError('Native input transport closed')
        remaining = remaining[written:]
    stream.flush()
