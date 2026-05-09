#!/usr/bin/env python3
"""Debug-only HTTP bridge to the local Gemma 4 CoreML-LLM smoke binary."""

from __future__ import annotations

import argparse
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class GemmaRuntimeHandler(BaseHTTPRequestHandler):
    binary: Path
    model_dir: Path

    def do_POST(self) -> None:
        if self.path != "/generate":
            self._send_json(404, {"error": "not_found"})
            return

        try:
            length = int(self.headers.get("content-length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            prompt = str(payload["prompt"]).strip()
            max_tokens = int(payload.get("max_tokens", 32))
            model_id = str(payload.get("model_id", "gemma-4-e2b-it-coreml-ios"))
            if not prompt:
                raise ValueError("prompt must not be empty")
        except Exception as exc:  # noqa: BLE001
            self._send_json(400, {"error": str(exc)})
            return

        print(
            "[gemma-http] generate "
            f"model_id={model_id} prompt_len={len(prompt)} "
            f"max_tokens={max_tokens}"
        )
        command = [
            str(self.binary),
            str(self.model_dir),
            prompt,
            str(max_tokens),
        ]
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
                timeout=600,
            )
        except subprocess.CalledProcessError as exc:
            self._send_json(
                500,
                {
                    "error": "gemma_runtime_failed",
                    "stdout": exc.stdout[-4000:],
                    "stderr": exc.stderr[-4000:],
                },
            )
            return
        except subprocess.TimeoutExpired:
            self._send_json(504, {"error": "gemma_runtime_timeout"})
            return

        text = _extract_generated_text(completed.stdout)
        self._send_json(
            200,
            {
                "model_id": model_id,
                "text": text,
                "debug_runtime": "coreml-llm-smoke",
            },
        )

    def log_message(self, fmt: str, *args: object) -> None:
        print("[gemma-http] " + fmt % args)

    def _send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _extract_generated_text(stdout: str) -> str:
    marker = "[smoke] loading model from:"
    if marker in stdout:
        stdout = stdout[: stdout.index(marker)]
    return stdout.replace("<pad>", "").strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    if not args.binary.exists():
        raise SystemExit(f"missing smoke binary: {args.binary}")
    if not args.model_dir.exists():
        raise SystemExit(f"missing model dir: {args.model_dir}")

    GemmaRuntimeHandler.binary = args.binary
    GemmaRuntimeHandler.model_dir = args.model_dir
    server = ThreadingHTTPServer((args.host, args.port), GemmaRuntimeHandler)
    print(
        f"[gemma-http] serving {args.model_dir} via {args.binary} "
        f"at http://{args.host}:{args.port}/generate"
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
