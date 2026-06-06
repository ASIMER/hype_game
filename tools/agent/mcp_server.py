#!/usr/bin/env python3
"""Stdlib-only MCP server (JSON-RPC 2.0 over stdio) for the hype-game agent.

Exposes the in-game control protocol as MCP tools. Each tool forwards a single
command to the Godot control server on 127.0.0.1:24700 by reusing play.py's
send(). No third-party packages -- this implements the slice of the MCP wire
protocol the client needs by hand.

Wire format: one JSON-RPC object per line on stdin; one JSON-RPC response per
line on stdout. Logs go to stderr ONLY -- stdout must stay pure JSON-RPC.
"""

import json
import os
import sys

# Import send() from the sibling play.py regardless of cwd.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from play import send, AgentError, DEFAULT_HOST, DEFAULT_PORT  # noqa: E402

# Target a specific game instance so several MCP servers (e.g. one per git worktree) each
# drive their own `--agent-port N` instance without getting confused. Port resolution, in
# order: (1) the AGENT_PORT env var (set by .mcp.json from $HYPE_AGENT_PORT), (2) a
# gitignored `tools/agent/.agent_port` pin file (written by launch_agents.ps1 per worktree),
# (3) the 24700 default. The file fallback means a worktree pins its port with zero env setup.
AGENT_HOST = os.environ.get("AGENT_HOST", DEFAULT_HOST)


def _resolve_agent_port():
    env = os.environ.get("AGENT_PORT", "").strip()
    if env.isdigit():
        return int(env)
    pin = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".agent_port")
    try:
        with open(pin) as f:
            val = f.read().strip()
            if val.isdigit():
                return int(val)
    except OSError:
        pass
    return DEFAULT_PORT


AGENT_PORT = _resolve_agent_port()

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "hype-game", "version": "1.0.0"}

# Tool name -> (description, JSON-schema input properties, required list).
TOOLS = [
    {
        "name": "game_state",
        "description": "Get the full world/player state from the running game "
        "(phase, wave, player pose/health, inventory, enemies, extraction, fps).",
        "inputSchema": {"type": "object", "properties": {}},
        "_build": lambda a: {"cmd": "state"},
    },
    {
        "name": "game_move",
        "description": "Move the player. x = strafe (-1..1), y = forward(+)/back(-) "
        "(-1..1), duration in seconds. Blocks until the move finishes.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "number", "description": "strafe, -1..1"},
                "y": {"type": "number", "description": "forward(+)/back(-), -1..1"},
                "duration": {"type": "number", "description": "seconds to hold"},
            },
            "required": ["x", "y", "duration"],
        },
        "_build": lambda a: {
            "cmd": "move",
            "x": float(a["x"]),
            "y": float(a["y"]),
            "duration": float(a["duration"]),
        },
    },
    {
        "name": "game_look",
        "description": "Rotate the camera by dx (yaw) and dy (pitch), in radians.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "dx": {"type": "number", "description": "yaw delta, radians"},
                "dy": {"type": "number", "description": "pitch delta, radians"},
            },
            "required": ["dx", "dy"],
        },
        "_build": lambda a: {"cmd": "look", "dx": float(a["dx"]), "dy": float(a["dy"])},
    },
    {
        "name": "game_aim",
        "description": "Point the player's camera exactly at an enemy (engine-side "
        "math). Use before game_fire. target is 'nearest' or an enemy name.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "'nearest' or a specific enemy name",
                }
            },
        },
        "_build": lambda a: {"cmd": "aim", "target": str(a.get("target", "nearest"))},
    },
    {
        "name": "game_goto",
        "description": "Face a world XZ point and walk forward toward it for duration "
        "seconds. Blocks until the walk finishes.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "number", "description": "world X"},
                "z": {"type": "number", "description": "world Z"},
                "duration": {"type": "number", "description": "seconds to walk"},
            },
            "required": ["x", "z"],
        },
        "_build": lambda a: {
            "cmd": "goto",
            "x": float(a["x"]),
            "z": float(a["z"]),
            "duration": float(a.get("duration", 0.5)),
        },
    },
    {
        "name": "game_fire",
        "description": "Hold fire for duration seconds. Blocks until firing ends.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "duration": {"type": "number", "description": "seconds to hold fire"}
            },
            "required": ["duration"],
        },
        "_build": lambda a: {"cmd": "fire", "duration": float(a["duration"])},
    },
    {
        "name": "game_sprint",
        "description": "Turn sprint on or off.",
        "inputSchema": {
            "type": "object",
            "properties": {"on": {"type": "boolean"}},
            "required": ["on"],
        },
        "_build": lambda a: {"cmd": "sprint", "on": bool(a["on"])},
    },
    {
        "name": "game_act",
        "description": "Perform a one-shot action.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["jump", "interact", "reload", "toggle_inventory"],
                }
            },
            "required": ["action"],
        },
        "_build": lambda a: {"cmd": "act", "action": str(a["action"])},
    },
    {
        "name": "game_screenshot",
        "description": "Take a screenshot; returns the absolute path to the PNG.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
        "_build": lambda a: {"cmd": "screenshot", "name": str(a["name"])},
    },
]

TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


def log(*parts):
    """Write a diagnostic line to stderr (never stdout)."""
    print("[mcp_server]", *parts, file=sys.stderr, flush=True)


def _public_tool(t):
    """Strip internal keys (_build) before advertising a tool."""
    return {k: v for k, v in t.items() if not k.startswith("_")}


def _result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def handle_request(msg):
    """Dispatch a single JSON-RPC request; return a response dict or None.

    None is returned for notifications (no id), which get no reply.
    """
    method = msg.get("method")
    req_id = msg.get("id")

    if method == "initialize":
        return _result(
            req_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "serverInfo": SERVER_INFO,
                "capabilities": {"tools": {}},
            },
        )

    if method == "notifications/initialized":
        return None  # notification, no response

    if method == "tools/list":
        return _result(req_id, {"tools": [_public_tool(t) for t in TOOLS]})

    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        tool = TOOLS_BY_NAME.get(name)
        if tool is None:
            return _error(req_id, -32602, "Unknown tool: {}".format(name))
        try:
            cmd = tool["_build"](arguments)
        except (KeyError, TypeError, ValueError) as exc:
            return _error(req_id, -32602, "Bad arguments for {}: {}".format(name, exc))

        try:
            resp = send(cmd, host=AGENT_HOST, port=AGENT_PORT)
        except AgentError as exc:
            # Report tool-level failure as an MCP error result, not a transport error.
            return _result(
                req_id,
                {
                    "content": [{"type": "text", "text": str(exc)}],
                    "isError": True,
                },
            )

        # Screenshot returns just the path for convenience; others return JSON.
        if name == "game_screenshot" and resp.get("ok") and resp.get("path"):
            text = resp["path"]
        else:
            text = json.dumps(resp)
        return _result(
            req_id,
            {
                "content": [{"type": "text", "text": text}],
                "isError": not bool(resp.get("ok", False)),
            },
        )

    # Unknown method.
    if req_id is None:
        return None  # unknown notification: ignore
    return _error(req_id, -32601, "Method not found: {}".format(method))


def main():
    log("starting; forwarding to {}:{}".format(AGENT_HOST, AGENT_PORT))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError as exc:
            log("dropping non-JSON line:", exc)
            continue

        try:
            resp = handle_request(msg)
        except Exception as exc:  # noqa: BLE001 - never crash the loop
            log("handler error:", exc)
            resp = _error(msg.get("id"), -32603, "Internal error: {}".format(exc))

        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
