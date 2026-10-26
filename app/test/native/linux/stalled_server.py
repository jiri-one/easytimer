#!/usr/bin/env python3
import os
import socket
import subprocess
import sys
import tempfile
import threading

with tempfile.TemporaryDirectory(prefix="easytimer-pulse-") as directory:
    address = os.path.join(directory, "native")
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(address)
    listener.listen()
    listener.settimeout(0.1)
    stopped = threading.Event()
    clients = []

    def accept_clients():
        while not stopped.is_set():
            try:
                client, _ = listener.accept()
                clients.append(client)
            except TimeoutError:
                pass

    accepting = threading.Thread(target=accept_clients)
    accepting.start()
    try:
        result = subprocess.run(
            [sys.argv[1], "stalled"],
            env={**os.environ, "PULSE_SERVER": "unix:" + address},
            timeout=10,
            check=False,
        )
    finally:
        stopped.set()
        accepting.join()
        listener.close()
        for client in clients:
            client.close()
    if result.returncode == 0 and len(clients) < 4:
        raise RuntimeError("probe did not open all expected server connections")
    sys.exit(result.returncode)
