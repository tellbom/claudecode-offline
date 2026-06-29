#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLAUDE_OPENAI_COMPAT_ENV:-${SCRIPT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  umask 077
  cat > "${ENV_FILE}" <<'ENV'
# Claude Code -> OpenAI-compatible adapter config.
# Edit this file; the launcher loads it automatically.

OPENAI_COMPAT_BASE_URL=https://api.deepseek.com/v1
OPENAI_COMPAT_MODEL=deepseek-v4-flash

# Put your OpenAI-compatible API key here. Do not commit this file.
OPENAI_COMPAT_API_KEY=

# DeepSeek v4 flash thinking mode is often slow for agent workloads.
# Use disabled for lower latency; use enabled when you explicitly need reasoning mode.
OPENAI_COMPAT_THINKING_TYPE=disabled
# OPENAI_COMPAT_REASONING_EFFORT=high

# Keep raw reasoning hidden by default. Set to 1 only for local debugging.
OPENAI_COMPAT_FORWARD_REASONING=0

# Some OpenAI-compatible gateways reject stream_options.
OPENAI_COMPAT_INCLUDE_USAGE=1

# Set to 1 to print adapter diagnostics to stderr/proxy.log.
OPENAI_COMPAT_DEBUG=0
ENV
  echo "Created config file: ${ENV_FILE}" >&2
  echo "Edit OPENAI_COMPAT_API_KEY and rerun this script." >&2
  exit 2
fi

set -a
# shellcheck source=/dev/null
. "${ENV_FILE}"
set +a

UPSTREAM_BASE="${OPENAI_COMPAT_BASE_URL:-https://api.deepseek.com/v1}"
MODEL="${OPENAI_COMPAT_MODEL:-${API_MODEL:-${ANTHROPIC_MODEL:-deepseek-v4-flash}}}"

if [[ -z "${OPENAI_COMPAT_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}}}" ]]; then
  echo "ERROR: set OPENAI_COMPAT_API_KEY in ${ENV_FILE}, or set OPENAI_API_KEY/ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN in the current shell." >&2
  exit 2
fi

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude not found. Run install_claude_offline.sh first." >&2
  exit 127
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for the local protocol adapter." >&2
  exit 127
fi

tmpdir="$(mktemp -d)"
proxy_pid=""
cleanup() {
  set +e
  if [[ -n "${proxy_pid}" ]]; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat > "${tmpdir}/anthropic_to_openai_proxy.py" <<'PY'
#!/usr/bin/env python3
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import json
import os
import time
import urllib.error
import urllib.request

UPSTREAM = os.environ.get("UPSTREAM_BASE", "https://api.deepseek.com/v1").rstrip("/")
PORT_FILE = os.environ["PORT_FILE"]
MODEL = os.environ.get("MODEL") or "deepseek-v4-flash"
THINKING_TYPE = os.environ.get("OPENAI_COMPAT_THINKING_TYPE", "").strip().lower()
REASONING_EFFORT = os.environ.get("OPENAI_COMPAT_REASONING_EFFORT", "").strip()
FORWARD_REASONING = os.environ.get("OPENAI_COMPAT_FORWARD_REASONING", "0").strip().lower() in ("1", "true", "yes", "on")
INCLUDE_USAGE = os.environ.get("OPENAI_COMPAT_INCLUDE_USAGE", "1").strip().lower() not in ("0", "false", "no", "off")
DEBUG = os.environ.get("OPENAI_COMPAT_DEBUG", "0").strip().lower() in ("1", "true", "yes", "on")
UPSTREAM_API_KEY = (
    os.environ.get("OPENAI_COMPAT_API_KEY")
    or os.environ.get("OPENAI_API_KEY")
    or os.environ.get("ANTHROPIC_API_KEY")
    or os.environ.get("ANTHROPIC_AUTH_TOKEN")
    or ""
)


def debug(message):
    if DEBUG:
        print(f"[openai-compat] {message}", flush=True)


def text_from_anthropic_content(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return "" if content is None else str(content)
    parts = []
    for block in content:
        if isinstance(block, str):
            parts.append(block)
        elif isinstance(block, dict):
            if block.get("type") == "text":
                parts.append(str(block.get("text", "")))
            elif block.get("type") == "image":
                parts.append("[image omitted by OpenAI-compatible adapter]")
    return "\n".join(part for part in parts if part)


def tool_result_text(block):
    content = block.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text", "")))
            elif isinstance(item, dict):
                parts.append(json.dumps(item, ensure_ascii=False))
        return "\n".join(parts)
    return json.dumps(content, ensure_ascii=False)


def anthropic_messages_to_openai(messages):
    out = []
    for message in messages or []:
        role = message.get("role", "user")
        content = message.get("content", "")

        if role == "assistant" and isinstance(content, list):
            text_parts = []
            tool_calls = []
            for block in content:
                if not isinstance(block, dict):
                    text_parts.append(str(block))
                    continue
                block_type = block.get("type")
                if block_type == "text":
                    text_parts.append(str(block.get("text", "")))
                elif block_type == "tool_use":
                    tool_calls.append(
                        {
                            "id": block.get("id") or f"toolu_{len(tool_calls) + 1}",
                            "type": "function",
                            "function": {
                                "name": block.get("name", ""),
                                "arguments": json.dumps(block.get("input") or {}, ensure_ascii=False),
                            },
                        }
                    )
            openai_message = {"role": "assistant", "content": "\n".join(p for p in text_parts if p) or None}
            if tool_calls:
                openai_message["tool_calls"] = tool_calls
            out.append(openai_message)
            continue

        if role == "user" and isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    if text_parts:
                        out.append({"role": "user", "content": "\n".join(text_parts)})
                        text_parts = []
                    out.append(
                        {
                            "role": "tool",
                            "tool_call_id": block.get("tool_use_id", ""),
                            "content": tool_result_text(block),
                        }
                    )
                else:
                    text = text_from_anthropic_content([block])
                    if text:
                        text_parts.append(text)
            if text_parts:
                out.append({"role": "user", "content": "\n".join(text_parts)})
            continue

        out.append({"role": role, "content": text_from_anthropic_content(content)})
    return out


def anthropic_tools_to_openai(tools):
    out = []
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if not name:
            continue
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": tool.get("description") or "",
                    "parameters": tool.get("input_schema") or {"type": "object", "properties": {}},
                },
            }
        )
    return out


def anthropic_tool_choice_to_openai(choice):
    if not isinstance(choice, dict):
        return None
    choice_type = choice.get("type")
    if choice_type == "auto":
        return "auto"
    if choice_type == "any":
        return "required"
    if choice_type == "none":
        return "none"
    if choice_type == "tool" and choice.get("name"):
        return {"type": "function", "function": {"name": choice["name"]}}
    return None


def build_openai_payload(payload):
    messages = []
    system = payload.get("system")
    system_text = text_from_anthropic_content(system)
    if system_text:
        messages.append({"role": "system", "content": system_text})
    messages.extend(anthropic_messages_to_openai(payload.get("messages", [])))

    out = {
        "model": MODEL,
        "messages": messages,
        "stream": bool(payload.get("stream")),
    }
    if payload.get("max_tokens") is not None:
        out["max_tokens"] = payload["max_tokens"]
    if payload.get("temperature") is not None:
        out["temperature"] = payload["temperature"]
    if payload.get("top_p") is not None:
        out["top_p"] = payload["top_p"]
    if payload.get("stop_sequences"):
        out["stop"] = payload["stop_sequences"]
    if out["stream"] and INCLUDE_USAGE:
        out["stream_options"] = {"include_usage": True}
    if THINKING_TYPE in ("enabled", "disabled"):
        out["thinking"] = {"type": THINKING_TYPE}
    if REASONING_EFFORT:
        out["reasoning_effort"] = REASONING_EFFORT

    tools = anthropic_tools_to_openai(payload.get("tools"))
    if tools:
        out["tools"] = tools
        tool_choice = anthropic_tool_choice_to_openai(payload.get("tool_choice"))
        if tool_choice is not None:
            out["tool_choice"] = tool_choice
    return out


def anthropic_error(error_type, message):
    return {"type": "error", "error": {"type": error_type, "message": message}}


def openai_to_anthropic_response(openai_response, requested_model):
    choice = (openai_response.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = []

    text = message.get("content")
    if text:
        content.append({"type": "text", "text": text})

    tool_calls = message.get("tool_calls") or []
    for call in tool_calls:
        function = call.get("function") or {}
        arguments = function.get("arguments") or "{}"
        try:
            parsed_arguments = json.loads(arguments)
        except Exception:
            parsed_arguments = {"_raw_arguments": arguments}
        content.append(
            {
                "type": "tool_use",
                "id": call.get("id") or f"call_{len(content) + 1}",
                "name": function.get("name", ""),
                "input": parsed_arguments,
            }
        )

    finish_reason = choice.get("finish_reason")
    if tool_calls:
        stop_reason = "tool_use"
    elif finish_reason == "length":
        stop_reason = "max_tokens"
    else:
        stop_reason = "end_turn"

    usage = openai_response.get("usage") or {}
    return {
        "id": openai_response.get("id") or f"msg_{int(time.time() * 1000)}",
        "type": "message",
        "role": "assistant",
        "model": openai_response.get("model") or requested_model,
        "content": content or [{"type": "text", "text": ""}],
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


def anthropic_message_start(message_id, model, input_tokens=0):
    return {
        "type": "message_start",
        "message": {
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {
                "input_tokens": input_tokens,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 0,
            },
        },
    }


class StreamState:
    def __init__(self, model):
        self.message_id = f"msg_{int(time.time() * 1000)}"
        self.model = model
        self.text_started = False
        self.text_index = None
        self.next_index = 0
        self.tool_indexes = {}
        self.tool_buffers = {}
        self.stop_reason = "end_turn"
        self.output_tokens = 0
        self.input_tokens = 0

    def start_text(self, send_event):
        if self.text_started:
            return
        self.text_index = self.next_index
        self.next_index += 1
        self.text_started = True
        send_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": self.text_index,
                "content_block": {"type": "text", "text": ""},
            },
        )

    def text_delta(self, text, send_event):
        if not text:
            return
        self.start_text(send_event)
        send_event(
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": self.text_index,
                "delta": {"type": "text_delta", "text": text},
            },
        )

    def reasoning_delta(self, text, send_event):
        if not text:
            return
        if FORWARD_REASONING:
            self.text_delta(text, send_event)
        else:
            send_event("ping", {"type": "ping"})

    def tool_delta(self, tool_call, send_event):
        call_index = tool_call.get("index", 0)
        function = tool_call.get("function") or {}
        buf = self.tool_buffers.setdefault(call_index, {"id": "", "name": "", "arguments": ""})
        if tool_call.get("id"):
            buf["id"] = tool_call["id"]
        if function.get("name"):
            buf["name"] = function["name"]
        args_delta = function.get("arguments") or ""

        if call_index not in self.tool_indexes:
            if not (buf["id"] and buf["name"]):
                buf["arguments"] += args_delta
                return
            self.tool_indexes[call_index] = self.next_index
            self.next_index += 1
            send_event(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": self.tool_indexes[call_index],
                    "content_block": {
                        "type": "tool_use",
                        "id": buf["id"],
                        "name": buf["name"],
                        "input": {},
                    },
                },
            )
            pending_args = buf["arguments"] + args_delta
            buf["arguments"] = pending_args
        else:
            pending_args = args_delta
            buf["arguments"] += args_delta

        if pending_args:
            send_event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": self.tool_indexes[call_index],
                    "delta": {"type": "input_json_delta", "partial_json": pending_args},
                },
            )

    def finish_blocks(self, send_event):
        if self.text_started:
            send_event("content_block_stop", {"type": "content_block_stop", "index": self.text_index})
        for call_index in sorted(self.tool_indexes, key=self.tool_indexes.get):
            send_event("content_block_stop", {"type": "content_block_stop", "index": self.tool_indexes[call_index]})


def estimate_tokens(payload):
    text = json.dumps(payload.get("messages", []), ensure_ascii=False)
    text += json.dumps(payload.get("system", ""), ensure_ascii=False)
    return max(1, min(200000, len(text) // 4 + 8))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_json(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_sse_headers(self, code=200):
        self.send_response(code)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.send_header("x-accel-buffering", "no")
        self.end_headers()
        self.close_connection = True

    def write_sse_event(self, event, payload):
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        self.wfile.write(f"event: {event}\n".encode("utf-8"))
        self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
        self.wfile.flush()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path.split("?", 1)[0] in ("", "/", "/v1", "/health"):
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"error": {"type": "not_found", "message": self.path}})

    def forward_stream(self, request, model):
        state = StreamState(model)
        self.send_sse_headers()
        self.write_sse_event("message_start", anthropic_message_start(state.message_id, model))

        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                for raw_line in response:
                    line = raw_line.decode("utf-8", "replace").strip()
                    if not line or line.startswith(":"):
                        continue
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except Exception:
                        continue

                    usage = chunk.get("usage") or {}
                    state.input_tokens = usage.get("prompt_tokens", state.input_tokens)
                    state.output_tokens = usage.get("completion_tokens", state.output_tokens)
                    if chunk.get("id"):
                        state.message_id = chunk["id"]
                    if chunk.get("model"):
                        state.model = chunk["model"]

                    choice = (chunk.get("choices") or [{}])[0]
                    delta = choice.get("delta") or {}
                    if "content" in delta:
                        state.text_delta(delta.get("content") or "", self.write_sse_event)
                    reasoning = delta.get("reasoning_content") or delta.get("reasoning")
                    if reasoning:
                        state.reasoning_delta(str(reasoning), self.write_sse_event)
                    for tool_call in delta.get("tool_calls") or []:
                        state.stop_reason = "tool_use"
                        state.tool_delta(tool_call, self.write_sse_event)

                    finish_reason = choice.get("finish_reason")
                    if finish_reason == "length":
                        state.stop_reason = "max_tokens"
                    elif finish_reason == "tool_calls":
                        state.stop_reason = "tool_use"
                    elif finish_reason in ("stop", "content_filter"):
                        state.stop_reason = "end_turn"

            state.finish_blocks(self.write_sse_event)
            self.write_sse_event(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": state.stop_reason, "stop_sequence": None},
                    "usage": {"output_tokens": state.output_tokens},
                },
            )
            self.write_sse_event("message_stop", {"type": "message_stop"})
        except urllib.error.HTTPError as exc:
            data = exc.read()
            try:
                error_payload = json.loads(data.decode("utf-8"))
                message = json.dumps(error_payload, ensure_ascii=False)
            except Exception:
                message = data.decode("utf-8", "replace")
            self.write_sse_event("error", anthropic_error("upstream_error", message))
        except Exception as exc:
            self.write_sse_event("error", anthropic_error("proxy_error", str(exc)))

    def do_POST(self):
        length = int(self.headers.get("content-length") or "0")
        body = self.rfile.read(length)
        path = self.path.split("?", 1)[0]

        try:
            payload = json.loads(body.decode("utf-8") or "{}")
        except Exception as exc:
            self.send_json(400, {"error": {"type": "invalid_request_error", "message": str(exc)}})
            return

        if path.endswith("/messages/count_tokens"):
            self.send_json(200, {"input_tokens": estimate_tokens(payload)})
            return

        if path.endswith("/messages"):
            openai_payload = build_openai_payload(payload)
            debug(
                "POST /messages stream=%s model=%s messages=%s tools=%s thinking=%s effort=%s"
                % (
                    openai_payload.get("stream"),
                    openai_payload.get("model"),
                    len(openai_payload.get("messages") or []),
                    bool(openai_payload.get("tools")),
                    openai_payload.get("thinking"),
                    openai_payload.get("reasoning_effort"),
                )
            )
            headers = {
                "content-type": "application/json",
                "authorization": f"Bearer {UPSTREAM_API_KEY}",
            }
            if openai_payload["stream"]:
                headers["accept"] = "text/event-stream"
            request = urllib.request.Request(
                UPSTREAM + "/chat/completions",
                data=json.dumps(openai_payload, ensure_ascii=False).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            if openai_payload["stream"]:
                self.forward_stream(request, openai_payload["model"])
                return
            try:
                with urllib.request.urlopen(request, timeout=300) as response:
                    openai_response = json.loads(response.read().decode("utf-8"))
                self.send_json(200, openai_to_anthropic_response(openai_response, openai_payload["model"]))
            except urllib.error.HTTPError as exc:
                data = exc.read()
                try:
                    error_payload = json.loads(data.decode("utf-8"))
                except Exception:
                    error_payload = {"error": {"type": "upstream_error", "message": data.decode("utf-8", "replace")}}
                self.send_json(exc.code, error_payload)
            except Exception as exc:
                self.send_json(502, {"error": {"type": "proxy_error", "message": str(exc)}})
            return

        self.send_json(404, {"error": {"type": "not_found", "message": self.path}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY

export UPSTREAM_BASE
export MODEL
export PORT_FILE="${tmpdir}/port"
python3 "${tmpdir}/anthropic_to_openai_proxy.py" > "${tmpdir}/proxy.log" 2>&1 &
proxy_pid="$!"

for _ in $(seq 1 50); do
  if [[ -s "${PORT_FILE}" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -s "${PORT_FILE}" ]]; then
  echo "ERROR: local protocol adapter failed to start." >&2
  sed -n '1,80p' "${tmpdir}/proxy.log" >&2 || true
  exit 1
fi

port="$(cat "${PORT_FILE}")"

export DISABLE_AUTOUPDATER=1
export DISABLE_UPDATES=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_FEEDBACK_COMMAND=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1

exec env ANTHROPIC_BASE_URL="http://127.0.0.1:${port}/v1" \
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_COMPAT_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}}}" \
  claude --bare --model "${MODEL}" "$@"
