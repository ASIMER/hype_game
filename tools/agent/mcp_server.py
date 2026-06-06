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
import socket
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

# Shared port schema snippet injected into every tool's inputSchema.
_PORT_PROP = {
    "port": {
        "type": "number",
        "description": (
            "Control port of the target game instance (default: the MCP-server-level "
            "pinned port, usually 24700). Set to a different value to drive a specific "
            "instance when several are running via launch_agents.ps1."
        ),
    }
}

# Tool name -> (description, JSON-schema input properties, required list).
TOOLS = [
    {
        "name": "game_state",
        "description": "Get the full world/player state from the running game "
        "(phase, wave, player pose/health, inventory, enemies, extraction, fps).",
        "inputSchema": {"type": "object", "properties": dict(_PORT_PROP)},
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
                **_PORT_PROP,
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
                **_PORT_PROP,
            },
            "required": ["dx", "dy"],
        },
        "_build": lambda a: {"cmd": "look", "dx": float(a["dx"]), "dy": float(a["dy"])},
    },
    {
        "name": "game_aim",
        "description": (
            "Point the player's camera exactly at a target (engine-side math). Use before "
            "game_fire. target='nearest' (default), an enemy name, 'weakpoint' (nearest "
            "enemy's weak spot), or 'point' (aim at world coords x,y,z)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "'nearest', enemy name, 'weakpoint', or 'point'",
                },
                "x": {"type": "number", "description": "world X (used when target='point')"},
                "y": {"type": "number", "description": "world Y (used when target='point')"},
                "z": {"type": "number", "description": "world Z (used when target='point')"},
                **_PORT_PROP,
            },
        },
        "_build": lambda a: {
            k: v for k, v in {
                "cmd": "aim",
                "target": str(a.get("target", "nearest")),
                "x": float(a["x"]) if "x" in a else None,
                "y": float(a["y"]) if "y" in a else None,
                "z": float(a["z"]) if "z" in a else None,
            }.items() if v is not None
        },
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
                **_PORT_PROP,
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
                "duration": {"type": "number", "description": "seconds to hold fire"},
                **_PORT_PROP,
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
            "properties": {"on": {"type": "boolean"}, **_PORT_PROP},
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
                },
                **_PORT_PROP,
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
            "properties": {"name": {"type": "string"}, **_PORT_PROP},
            "required": ["name"],
        },
        "_build": lambda a: {"cmd": "screenshot", "name": str(a["name"])},
    },
    # -------------------------------------------------------------------------
    # Generic forwarder
    # -------------------------------------------------------------------------
    {
        "name": "game_raw",
        "description": (
            "Forward any AgentBridge command verbatim. Provide either 'json' (a JSON string) "
            "or 'cmd' (an object). This lets any current or future command be driven from MCP "
            "with zero server changes — use it for commands not yet wrapped in a typed tool."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "json": {
                    "type": "string",
                    "description": "JSON string of the command dict to send.",
                },
                "cmd": {
                    "type": "object",
                    "description": "Command dict to send (alternative to 'json').",
                },
                **_PORT_PROP,
            },
        },
        "_build": lambda a: _build_raw(a),
    },
    # -------------------------------------------------------------------------
    # Multi-instance discovery
    # -------------------------------------------------------------------------
    {
        "name": "game_instances",
        "description": (
            "Probe a range of control ports and return the list of live game instances. "
            "For each reachable port, also fetches peer_id, phase, and players_count from state."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "base": {
                    "type": "number",
                    "description": "First port to probe (default 24700).",
                },
                "count": {
                    "type": "number",
                    "description": "Number of consecutive ports to check (default 8).",
                },
            },
        },
        # _build not used — handled specially in dispatch
        "_build": lambda a: {"cmd": "__game_instances__"},
    },
    # -------------------------------------------------------------------------
    # Multi-instance broadcast
    # -------------------------------------------------------------------------
    {
        "name": "game_broadcast",
        "description": (
            "Send the same command to multiple game instances at once. Specify target ports "
            "either as an explicit 'ports' list, or as a base+count range. Returns a list of "
            "{port, response} — dead ports record an error but do not abort."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "json": {
                    "type": "string",
                    "description": "JSON string of the command dict to broadcast.",
                },
                "cmd": {
                    "type": "object",
                    "description": "Command dict to broadcast (alternative to 'json').",
                },
                "ports": {
                    "type": "array",
                    "items": {"type": "number"},
                    "description": "Explicit list of control ports to target.",
                },
                "base": {
                    "type": "number",
                    "description": "First port of a consecutive range (used when 'ports' is absent).",
                },
                "count": {
                    "type": "number",
                    "description": "Number of ports in the range (default 8).",
                },
            },
        },
        # Handled specially in dispatch
        "_build": lambda a: {"cmd": "__game_broadcast__"},
    },
    # -------------------------------------------------------------------------
    # Ergonomic typed tools for new commands
    # -------------------------------------------------------------------------
    {
        "name": "game_hold",
        "description": (
            "Hold or release a sustained input. Unlike game_act (which taps once), this "
            "keeps the action pressed until you call it again with on=false."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["crouch", "interact", "carry", "jump", "fire", "sprint", "ads"],
                    "description": "Which input to hold or release.",
                },
                "on": {"type": "boolean", "description": "true = hold, false = release"},
                **_PORT_PROP,
            },
            "required": ["action", "on"],
        },
        "_build": lambda a: {"cmd": "hold", "action": str(a["action"]), "on": bool(a["on"])},
    },
    {
        "name": "game_damage",
        "description": (
            "Deal damage to a target. target='self', 'nearest', or an enemy name. "
            "weak=true routes through the enemy weak-point for the damage multiplier."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "'self', 'nearest', or a specific enemy name.",
                },
                "amount": {
                    "type": "number",
                    "description": "Damage amount (default 9999 = lethal for most enemies).",
                },
                "weak": {
                    "type": "boolean",
                    "description": "Route through weak-point for the damage multiplier.",
                },
                **_PORT_PROP,
            },
        },
        "_build": lambda a: {
            "cmd": "hurt",
            "target": str(a.get("target", "nearest")),
            "amount": float(a.get("amount", 9999)),
            "weak": bool(a.get("weak", False)),
        },
    },
    {
        "name": "game_kill",
        "description": "Instantly kill a target. target='self', 'nearest', or an enemy name.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "'self', 'nearest', or a specific enemy name.",
                },
                **_PORT_PROP,
            },
        },
        "_build": lambda a: {"cmd": "kill", "target": str(a.get("target", "nearest"))},
    },
    {
        "name": "game_down",
        "description": "Down (on=true) or revive (on=false) the local player.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "on": {"type": "boolean", "description": "true = down, false = revive"},
                **_PORT_PROP,
            },
            "required": ["on"],
        },
        "_build": lambda a: {"cmd": "down", "on": bool(a["on"])},
    },
    {
        "name": "game_crosshair",
        "description": (
            "Raycast from the camera along the current aim direction. Returns hit, entity, "
            "enemy_id, is_weakpoint, point (world XYZ), and dist."
        ),
        "inputSchema": {"type": "object", "properties": dict(_PORT_PROP)},
        "_build": lambda a: {"cmd": "crosshair"},
    },
    {
        "name": "game_set_progress",
        "description": (
            "Manipulate meta-progression values for testing. action is one of: "
            "add_xp, set_xp, set_level, add_rep, set_rep, add_mastery, set_mastery, "
            "skill_points, buy_skill, credit_kill. Supply only the fields relevant to the action."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "Progression action (e.g. 'add_xp', 'set_level').",
                },
                "amount": {"type": "number", "description": "Generic numeric amount."},
                "value": {"type": "number", "description": "Set-to value."},
                "weapon": {"type": "string", "description": "Weapon id (for mastery/perks)."},
                "level": {"type": "number", "description": "Target level."},
                "key": {"type": "string", "description": "Skill key (for buy_skill)."},
                **_PORT_PROP,
            },
            "required": ["action"],
        },
        "_build": lambda a: _build_prog(a),
    },
    {
        "name": "game_event",
        "description": (
            "Trigger or end a scripted in-game event. kind 0-3 selects the event type; "
            "end=true closes the currently active event."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "kind": {
                    "type": "number",
                    "description": "Event kind 0-3 (default 0).",
                },
                "end": {
                    "type": "boolean",
                    "description": "true = end the active event instead of starting one.",
                },
                **_PORT_PROP,
            },
        },
        "_build": lambda a: {
            "cmd": "event",
            "kind": int(a.get("kind", 0)),
            "end": bool(a.get("end", False)),
        },
    },
]

TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ---------------------------------------------------------------------------
# Helper builders for tools that need non-trivial logic
# ---------------------------------------------------------------------------

def _build_raw(a):
    """Parse game_raw arguments into a command dict."""
    if "json" in a and a["json"]:
        try:
            return json.loads(a["json"])
        except (ValueError, TypeError) as exc:
            raise ValueError("Invalid JSON in 'json' field: {}".format(exc))
    if "cmd" in a and a["cmd"]:
        return dict(a["cmd"])
    raise ValueError("game_raw requires either 'json' or 'cmd'.")


def _build_prog(a):
    """Build a prog command including only the fields the caller provided."""
    cmd = {"cmd": "prog", "action": str(a["action"])}
    for field in ("amount", "value", "weapon", "level", "key"):
        if field in a and a[field] is not None:
            cmd[field] = a[field]
    return cmd


def _probe_port(port):
    """Try a ping on port with a 1-second timeout. Returns True if alive."""
    try:
        resp = send({"cmd": "ping"}, host=AGENT_HOST, port=port, timeout=1.0)
        return resp.get("ok", False)
    except (AgentError, Exception):
        return False


def _instance_info(port):
    """Return {port, peer_id, phase, players_count} for a live port, or None."""
    if not _probe_port(port):
        return None
    try:
        state = send({"cmd": "state"}, host=AGENT_HOST, port=port, timeout=5.0)
        return {
            "port": port,
            "peer_id": state.get("peer_id"),
            "phase": state.get("phase"),
            "players_count": state.get("players_count"),
        }
    except (AgentError, Exception):
        return {"port": port, "peer_id": None, "phase": None, "players_count": None}


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


def _tool_result(req_id, text, is_error=False):
    return _result(req_id, {"content": [{"type": "text", "text": text}], "isError": is_error})


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

        # Per-call port: explicit argument overrides the server-level default.
        port = int(arguments.get("port") or AGENT_PORT)

        # --- game_instances: special dispatch (no send, probes N ports) ---
        if name == "game_instances":
            base = int(arguments.get("base") or 24700)
            count = int(arguments.get("count") or 8)
            results = []
            for p in range(base, base + count):
                info = _instance_info(p)
                if info is not None:
                    results.append(info)
            return _tool_result(req_id, json.dumps(results))

        # --- game_broadcast: special dispatch (fan-out) ---
        if name == "game_broadcast":
            # Resolve the command to send.
            try:
                bcast_cmd = _build_raw(arguments)
            except (ValueError, TypeError) as exc:
                return _error(req_id, -32602, "Bad arguments for game_broadcast: {}".format(exc))
            # Resolve target ports.
            if "ports" in arguments and arguments["ports"]:
                ports = [int(p) for p in arguments["ports"]]
            else:
                base = int(arguments.get("base") or 24700)
                count = int(arguments.get("count") or 8)
                ports = list(range(base, base + count))
            results = []
            for p in ports:
                try:
                    resp = send(bcast_cmd, host=AGENT_HOST, port=p, timeout=5.0)
                    results.append({"port": p, "response": resp})
                except AgentError as exc:
                    results.append({"port": p, "error": str(exc)})
                except Exception as exc:
                    results.append({"port": p, "error": "Unexpected: {}".format(exc)})
            return _tool_result(req_id, json.dumps(results))

        # --- Normal tools: build cmd dict and forward ---
        try:
            cmd = tool["_build"](arguments)
        except (KeyError, TypeError, ValueError) as exc:
            return _error(req_id, -32602, "Bad arguments for {}: {}".format(name, exc))

        try:
            resp = send(cmd, host=AGENT_HOST, port=port)
        except AgentError as exc:
            return _tool_result(req_id, str(exc), is_error=True)

        # Screenshot returns just the path for convenience; others return JSON.
        if name == "game_screenshot" and resp.get("ok") and resp.get("path"):
            text = resp["path"]
        else:
            text = json.dumps(resp)
        return _tool_result(req_id, text, is_error=not bool(resp.get("ok", False)))

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
