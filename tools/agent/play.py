#!/usr/bin/env python3
"""Control client for the hype-game in-game agent server.

Speaks the newline-delimited JSON protocol of the Godot control server that
listens on 127.0.0.1:24700 (Settings.AGENT_PORT) when the game runs in
--agent mode. Each call opens a socket, sends exactly one JSON object plus a
newline, reads exactly one JSON object terminated by a newline, then closes.

stdlib-only (socket, json, sys, argparse). Importable: use send(cmd_dict).
"""

import argparse
import json
import socket
import sys

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 24700


class AgentError(Exception):
    """Raised when the control server cannot be reached or replies badly."""


def send(cmd, host=DEFAULT_HOST, port=DEFAULT_PORT, timeout=None):
    """Send one command dict and return the parsed response dict.

    move/fire are blocking: the server replies only after the held duration
    elapses, so the socket timeout is sized to duration + 10s (min 15s).
    For short-lived probes pass an explicit timeout (e.g. 1.0).
    """
    if timeout is None:
        dur = 0.0
        try:
            dur = float(cmd.get("duration", 0.0) or 0.0)
        except (TypeError, ValueError):
            dur = 0.0
        timeout = max(15.0, dur + 10.0)

    line = (json.dumps(cmd) + "\n").encode("utf-8")
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(line)
            buf = bytearray()
            while b"\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
    except ConnectionRefusedError:
        raise AgentError(
            "Connection refused on {}:{} -- the game is not running, or its "
            "control server is not up. Launch the game in --agent mode "
            "first.".format(host, port)
        )
    except socket.timeout:
        raise AgentError(
            "Timed out after {:.0f}s waiting for the control server "
            "({}:{}).".format(timeout, host, port)
        )
    except OSError as exc:
        raise AgentError("Socket error talking to {}:{} -- {}".format(host, port, exc))

    if not buf:
        raise AgentError("Control server closed the connection with no reply.")

    raw = bytes(buf).split(b"\n", 1)[0]
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise AgentError("Malformed reply from server: {!r} ({})".format(raw, exc))


def _emit(resp, raw=False):
    """Print a response dict; return process exit code based on resp['ok']."""
    if raw:
        print(json.dumps(resp))
    else:
        print(json.dumps(resp, indent=2, sort_keys=True))
    return 0 if resp.get("ok") else 1


def _cast_num(s):
    """Try int then float; return string if neither works."""
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        return s


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="play.py", description="Control client for the hype-game agent server."
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help="control server host")
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT, help="control server port"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("ping", help="check the agent server is alive")

    p_state = sub.add_parser("state", help="dump full world/player state")
    p_state.add_argument("--raw", action="store_true", help="print compact JSON")

    p_move = sub.add_parser("move", help="move: x=strafe, y=forward(+)/back(-)")
    p_move.add_argument("x", type=float)
    p_move.add_argument("y", type=float)
    p_move.add_argument("duration", type=float, nargs="?", default=0.5)

    p_look = sub.add_parser("look", help="rotate camera by dx (yaw) / dy (pitch) radians")
    p_look.add_argument("dx", type=float)
    p_look.add_argument("dy", type=float)

    p_aim = sub.add_parser(
        "aim",
        help="point the camera at a target (engine-side). "
             "Usage: aim [nearest|<name>|weakpoint|point X Y Z]",
    )
    p_aim.add_argument("target", nargs="?", default="nearest")
    p_aim.add_argument("ax", nargs="?", type=float, default=None, metavar="X")
    p_aim.add_argument("ay", nargs="?", type=float, default=None, metavar="Y")
    p_aim.add_argument("az", nargs="?", type=float, default=None, metavar="Z")

    p_goto = sub.add_parser("goto", help="face world XZ point and walk forward toward it")
    p_goto.add_argument("x", type=float)
    p_goto.add_argument("z", type=float)
    p_goto.add_argument("duration", type=float, nargs="?", default=0.5)

    p_fire = sub.add_parser("fire", help="hold fire for duration seconds")
    p_fire.add_argument("duration", type=float, nargs="?", default=0.3)

    p_sprint = sub.add_parser("sprint", help="toggle sprint on/off")
    p_sprint.add_argument("on", choices=["on", "off"])

    p_act = sub.add_parser("act", help="one-shot action")
    p_act.add_argument(
        "action", choices=["jump", "interact", "reload", "toggle_inventory"]
    )

    p_shot = sub.add_parser("shot", help="take a screenshot; prints only its path")
    p_shot.add_argument("name")

    sub.add_parser("quit", help="ask the game to quit")

    # --- New commands ---

    p_hold = sub.add_parser(
        "hold",
        help="hold or release a sustained input: hold <action> on|off",
    )
    p_hold.add_argument(
        "action",
        choices=["crouch", "interact", "carry", "jump", "fire", "sprint", "ads"],
    )
    p_hold.add_argument("on", choices=["on", "off"])

    p_down = sub.add_parser("down", help="down or revive the local player: down on|off")
    p_down.add_argument("on", choices=["on", "off"])

    p_hurt = sub.add_parser(
        "hurt",
        help="deal damage: hurt <target> <amount> [weak]  (target: self|nearest|<name>)",
    )
    p_hurt.add_argument("target")
    p_hurt.add_argument("amount", type=float)
    p_hurt.add_argument("weak", nargs="?", default="")

    p_kill = sub.add_parser("kill", help="instantly kill target: kill [nearest|self|<name>]")
    p_kill.add_argument("target", nargs="?", default="nearest")

    p_heal = sub.add_parser("heal", help="heal the local player: heal <amount>")
    p_heal.add_argument("amount", type=float)

    p_sethp = sub.add_parser("sethp", help="set local player health to value: sethp <value>")
    p_sethp.add_argument("value", type=float)

    sub.add_parser("crosshair", help="raycast from the camera; returns hit info")

    p_prog = sub.add_parser(
        "prog",
        help="progression setter: prog <action> [key=value ...]\n"
             "  actions: add_xp set_xp set_level add_rep set_rep add_mastery\n"
             "           set_mastery skill_points buy_skill credit_kill",
    )
    p_prog.add_argument("action")
    p_prog.add_argument("pairs", nargs="*", metavar="key=value",
                        help="Extra fields, e.g. amount=500 weapon=rifle level=3")

    args = parser.parse_args(argv)

    # Build the protocol command from the parsed subcommand.
    if args.command == "ping":
        cmd = {"cmd": "ping"}
    elif args.command == "state":
        cmd = {"cmd": "state"}
    elif args.command == "move":
        cmd = {"cmd": "move", "x": args.x, "y": args.y, "duration": args.duration}
    elif args.command == "look":
        cmd = {"cmd": "look", "dx": args.dx, "dy": args.dy}
    elif args.command == "aim":
        cmd = {"cmd": "aim", "target": args.target}
        # For target="point", pass the world coords if provided.
        if args.ax is not None:
            cmd["x"] = args.ax
        if args.ay is not None:
            cmd["y"] = args.ay
        if args.az is not None:
            cmd["z"] = args.az
    elif args.command == "goto":
        # goto is blocking like move/fire; send() sizes the timeout off duration.
        cmd = {"cmd": "goto", "x": args.x, "z": args.z, "duration": args.duration}
    elif args.command == "fire":
        cmd = {"cmd": "fire", "duration": args.duration}
    elif args.command == "sprint":
        cmd = {"cmd": "sprint", "on": args.on == "on"}
    elif args.command == "act":
        cmd = {"cmd": "act", "action": args.action}
    elif args.command == "shot":
        cmd = {"cmd": "screenshot", "name": args.name}
    elif args.command == "quit":
        cmd = {"cmd": "quit"}
    elif args.command == "hold":
        cmd = {"cmd": "hold", "action": args.action, "on": args.on == "on"}
    elif args.command == "down":
        cmd = {"cmd": "down", "on": args.on == "on"}
    elif args.command == "hurt":
        cmd = {
            "cmd": "hurt",
            "target": args.target,
            "amount": args.amount,
            "weak": args.weak.lower() == "weak",
        }
    elif args.command == "kill":
        cmd = {"cmd": "kill", "target": args.target}
    elif args.command == "heal":
        cmd = {"cmd": "heal", "amount": args.amount}
    elif args.command == "sethp":
        cmd = {"cmd": "sethp", "value": args.value}
    elif args.command == "crosshair":
        cmd = {"cmd": "crosshair"}
    elif args.command == "prog":
        cmd = {"cmd": "prog", "action": args.action}
        for pair in args.pairs:
            if "=" not in pair:
                parser.error("prog extra args must be key=value, got: {}".format(pair))
            k, _, v = pair.partition("=")
            cmd[k.strip()] = _cast_num(v.strip())
    else:  # pragma: no cover - argparse enforces choices
        parser.error("unknown command")

    try:
        resp = send(cmd, host=args.host, port=args.port)
    except AgentError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    # `shot` prints only the absolute path on success for easy capture.
    if args.command == "shot":
        if resp.get("ok") and resp.get("path"):
            print(resp["path"])
            return 0
        print(json.dumps(resp), file=sys.stderr)
        return 1

    return _emit(resp, raw=getattr(args, "raw", False))


if __name__ == "__main__":
    sys.exit(main())
