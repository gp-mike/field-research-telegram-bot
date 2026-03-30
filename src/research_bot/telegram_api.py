from __future__ import annotations

import json
import ssl
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class TelegramAPI:
    def __init__(self, bot_token: str) -> None:
        self.bot_token = bot_token
        self.base_url = f"https://api.telegram.org/bot{bot_token}"
        self.file_base_url = f"https://api.telegram.org/file/bot{bot_token}"
        # DNS in some local/sandbox environments can intermittently fail.
        # This fallback talks to Telegram by IP with Host header override.
        self.fallback_base_url = f"https://149.154.167.220/bot{bot_token}"
        self.fallback_file_base_url = f"https://149.154.167.220/file/bot{bot_token}"
        self._insecure_ssl_context = ssl.create_default_context()
        self._insecure_ssl_context.check_hostname = False
        self._insecure_ssl_context.verify_mode = ssl.CERT_NONE

    def get_updates(self, offset: int | None = None, timeout: int = 30) -> list[dict[str, Any]]:
        payload: dict[str, Any] = {"timeout": timeout}
        if offset is not None:
            payload["offset"] = offset

        data = self._post_json("/getUpdates", payload)
        result = data.get("result", [])
        if not isinstance(result, list):
            return []
        return [item for item in result if isinstance(item, dict)]

    def send_message(self, chat_id: int, text: str) -> None:
        self._post_json(
            "/sendMessage",
            {
                "chat_id": chat_id,
                "text": text,
            },
        )

    def get_file_path(self, file_id: str) -> str:
        data = self._post_json("/getFile", {"file_id": file_id})
        result = data.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("Telegram getFile: invalid response payload.")
        file_path = result.get("file_path")
        if not isinstance(file_path, str) or not file_path:
            raise RuntimeError("Telegram getFile: missing file_path.")
        return file_path

    def download_file(self, file_id: str, destination: Path) -> Path:
        file_path = self.get_file_path(file_id)
        destination.parent.mkdir(parents=True, exist_ok=True)
        data = self._download_file_from_url(f"{self.file_base_url}/{file_path}")
        if data is None:
            data = self._download_file_from_url(
                f"{self.fallback_file_base_url}/{file_path}",
                host_header="api.telegram.org",
                insecure_tls=True,
            )
        if data is None:
            raise RuntimeError("Telegram file download failed via both primary and fallback routes.")

        destination.write_bytes(data)
        return destination

    def _post_json(self, method_path: str, payload: dict[str, Any]) -> dict[str, Any]:
        body = json.dumps(payload).encode("utf-8")
        raw = self._post_json_raw(
            url=f"{self.base_url}{method_path}",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        if raw is None:
            raw = self._post_json_raw(
                url=f"{self.fallback_base_url}{method_path}",
                body=body,
                headers={
                    "Content-Type": "application/json",
                    "Host": "api.telegram.org",
                },
                insecure_tls=True,
            )
        if raw is None:
            raise RuntimeError("Telegram API request failed via both primary and fallback routes.")

        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Telegram API returned non-JSON: {raw[:500]}") from exc
        if not isinstance(parsed, dict):
            raise RuntimeError("Telegram API returned unexpected payload.")
        if not parsed.get("ok"):
            raise RuntimeError(f"Telegram API error payload: {parsed}")
        return parsed

    def _post_json_raw(
        self,
        url: str,
        body: bytes,
        headers: dict[str, str],
        insecure_tls: bool = False,
    ) -> str | None:
        request = Request(url=url, data=body, method="POST", headers=headers)
        try:
            if insecure_tls:
                with urlopen(request, timeout=120, context=self._insecure_ssl_context) as response:
                    return response.read().decode("utf-8")
            with urlopen(request, timeout=120) as response:
                return response.read().decode("utf-8")
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Telegram API HTTP {exc.code}: {detail}") from exc
        except URLError:
            return None

    def _download_file_from_url(
        self,
        url: str,
        host_header: str | None = None,
        insecure_tls: bool = False,
    ) -> bytes | None:
        headers = {"Host": host_header} if host_header else {}
        request = Request(url=url, method="GET", headers=headers)
        try:
            if insecure_tls:
                with urlopen(request, timeout=120, context=self._insecure_ssl_context) as response:
                    return response.read()
            with urlopen(request, timeout=120) as response:
                return response.read()
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Telegram file download HTTP {exc.code}: {detail}") from exc
        except URLError:
            return None
