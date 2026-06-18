#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_BASE="${OPENAI_COMPAT_BASE_URL:-https://api.aigc369.com/v1}"
MODEL="${API_MODEL:-${ANTHROPIC_MODEL:-gpt-4o}}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY must be set in the current shell. It is not written to disk." >&2
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

UPSTREAM = os.environ.get("UPSTREAM_BASE", "https://api.aigc369.com/v1").rstrip("/")
PORT_FILE = os.environ["PORT_FILE"]


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
        "model": payload.get("model") or os.environ.get("MODEL") or "gpt-4o",
        "messages": messages,
        "stream": False,
    }
    if payload.get("max_tokens") is not None:
        out["max_tokens"] = payload["max_tokens"]
    if payload.get("temperature") is not None:
        out["temperature"] = payload["temperature"]
    if payload.get("top_p") is not None:
        out["top_p"] = payload["top_p"]
    if payload.get("stop_sequences"):
        out["stop"] = payload["stop_sequences"]

    tools = anthropic_tools_to_openai(payload.get("tools"))
    if tools:
        out["tools"] = tools
        tool_choice = anthropic_tool_choice_to_openai(payload.get("tool_choice"))
        if tool_choice is not None:
            out["tool_choice"] = tool_choice
    return out


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
            api_key = self.headers.get("x-api-key") or os.environ.get("ANTHROPIC_API_KEY", "")
            headers = {
                "content-type": "application/json",
                "authorization": f"Bearer {api_key}",
            }
            request = urllib.request.Request(
                UPSTREAM + "/chat/completions",
                data=json.dumps(openai_payload, ensure_ascii=False).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
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
  claude --bare --model "${MODEL}" "$@"
