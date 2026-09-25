"""
Talking to coachd. Also the CLI used to poke it by hand.

Usage:
  client.py ping
  client.py new [--level N]
  client.py move <uci>
  client.py state
  client.py analyse <fen> [--time 0.3]
  client.py shutdown
"""
import json
import os
import socket
import subprocess
import sys
import paths
import time

SOCKET_PATH = paths.data("coachd.sock")
COACHD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coachd.py")


def request(payload, socket_path=SOCKET_PATH, autostart=True):
    """One request, one reply. Starts the daemon if it isn't up yet."""
    try:
        return _send(payload, socket_path)
    except (FileNotFoundError, ConnectionRefusedError):
        if not autostart:
            raise
        start_daemon(socket_path)
        return _send(payload, socket_path)


def _send(payload, socket_path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(120)
    try:
        sock.connect(socket_path)
        sock.sendall((json.dumps(payload) + "\n").encode())
        with sock.makefile("rb") as f:
            line = f.readline()
    finally:
        sock.close()
    if not line:
        raise ConnectionError("coachd closed the connection without replying")
    return json.loads(line)


def start_daemon(socket_path=SOCKET_PATH, timeout=20):
    """Launch coachd detached and wait for it to answer."""
    subprocess.Popen(
        [sys.executable, COACHD, "--socket", socket_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return _send({"op": "ping"}, socket_path)
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.1)
    raise ConnectionError(f"coachd did not come up within {timeout}s")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip())
        sys.exit(2)

    cmd, rest = args[0], args[1:]
    if cmd == "new":
        payload = {"op": "new_game"}
        if "--level" in rest:
            payload["level"] = int(rest[rest.index("--level") + 1])
    elif cmd == "move":
        payload = {"op": "move"}
        if rest and not rest[0].startswith("--"):
            payload["uci"] = rest[0]
    elif cmd == "analyse":
        payload = {"op": "analyse"}
        if rest and not rest[0].startswith("--"):
            payload["fen"] = rest[0]
    else:
        payload = {"op": cmd}

    # Any --key value pair becomes a field on the request. This started as a
    # hand-written list of the flags each op happened to need, and every op
    # added since has been debugged twice: once for the real problem and once
    # for discovering the flag was being silently dropped. --fen, --uci and
    # --name each cost a round of that. Whatever the next op wants, it works.
    floats = {"time"}
    ints = {"count", "level", "plies"}
    i = 0
    while i < len(rest):
        token = rest[i]
        if token.startswith("--") and i + 1 < len(rest):
            key = token[2:]
            value = rest[i + 1]
            if key not in payload:
                if value[:1] in "[{":
                    # A list or object argument, e.g. --squares '["f4"]'.
                    # Without this it arrives as a string and anything that
                    # iterates it gets characters.
                    payload[key] = json.loads(value)
                elif key in floats:
                    payload[key] = float(value)
                elif key in ints:
                    # LEVELS is keyed by int; a float here is a KeyError.
                    payload[key] = int(value)
                else:
                    payload[key] = value
            i += 2
        else:
            i += 1

    print(json.dumps(request(payload), indent=2))


if __name__ == "__main__":
    main()
