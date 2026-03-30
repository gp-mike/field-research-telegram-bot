from __future__ import annotations

import json
import mimetypes
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4


class AIProcessor:
    def __init__(
        self,
        api_key: str | None,
        transcribe_model: str,
        summary_model: str,
        summary_prompt: str,
    ) -> None:
        self.api_key = api_key
        self.transcribe_model = transcribe_model
        self.summary_model = summary_model
        self.summary_prompt = summary_prompt

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)

    def transcribe_audio(self, audio_path: Path) -> str:
        if not self.enabled:
            return "[OPENAI_API_KEY не задан, транскрибация отключена]"

        fields = {"model": self.transcribe_model}
        files = {"file": audio_path}
        payload, content_type = _encode_multipart_form(fields, files)
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": content_type,
        }
        response_data = _http_json(
            "https://api.openai.com/v1/audio/transcriptions",
            headers=headers,
            data=payload,
        )
        text = response_data.get("text", "")
        if isinstance(text, str):
            return text.strip()
        return ""

    def summarize(self, transcript: str, title: str | None, notes: str | None) -> str:
        if not self.enabled:
            return "OPENAI_API_KEY не задан, AI-сводка отключена."

        payload_parts = []
        if title:
            payload_parts.append(f"Название интервью: {title}")
        if notes:
            payload_parts.append(f"Дополнительные заметки:\n{notes}")
        payload_parts.append(f"Транскрипт:\n{transcript}")
        user_payload = "\n\n".join(payload_parts)

        request_payload = {
            "model": self.summary_model,
            "input": [
                {"role": "system", "content": self.summary_prompt},
                {"role": "user", "content": user_payload},
            ],
            "max_output_tokens": 350,
        }
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

        response_data = _http_json(
            "https://api.openai.com/v1/responses",
            headers=headers,
            data=json.dumps(request_payload).encode("utf-8"),
        )
        summary = _extract_response_text(response_data).strip()
        if summary:
            return summary
        return "Не удалось получить краткое резюме по транскрипту."


def _extract_response_text(payload: dict[str, Any]) -> str:
    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text

    output_items = payload.get("output")
    if not isinstance(output_items, list):
        return ""

    chunks: list[str] = []
    for item in output_items:
        if not isinstance(item, dict):
            continue
        content = item.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            text = block.get("text")
            if isinstance(text, str):
                chunks.append(text)

    return "\n".join(chunks).strip()


def _encode_multipart_form(
    fields: dict[str, str],
    files: dict[str, Path],
) -> tuple[bytes, str]:
    boundary = f"----CodexFormBoundary{uuid4().hex}"
    chunks: list[bytes] = []

    for key, value in fields.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"),
                str(value).encode("utf-8"),
                b"\r\n",
            ]
        )

    for field_name, file_path in files.items():
        mime_type = mimetypes.guess_type(str(file_path))[0] or "application/octet-stream"
        file_name = file_path.name
        file_bytes = file_path.read_bytes()
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                (
                    f'Content-Disposition: form-data; name="{field_name}"; '
                    f'filename="{file_name}"\r\n'
                ).encode("utf-8"),
                f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"),
                file_bytes,
                b"\r\n",
            ]
        )

    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    body = b"".join(chunks)
    content_type = f"multipart/form-data; boundary={boundary}"
    return body, content_type


def _http_json(url: str, headers: dict[str, str], data: bytes | None = None) -> dict[str, Any]:
    request = Request(url=url, data=data, method="POST", headers=headers)
    try:
        with urlopen(request, timeout=120) as response:
            raw = response.read().decode("utf-8")
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Network error: {exc}") from exc

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Non-JSON response: {raw[:500]}") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("Unexpected API response format.")
    return parsed

