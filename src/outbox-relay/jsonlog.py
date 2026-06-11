"""Structured JSON logger: one JSON object per line on stdout, carrying a service
name and an optional correlation_id threaded through from the request.

Duplicated into each service directory on purpose — the services are separate
Docker build contexts with no shared package on PYTHONPATH (same reason
idempotency.py is duplicated), so a shared module isn't importable without a
Dockerfile change.
"""
import json
import logging
import sys
from datetime import datetime, timezone

# Default LogRecord attributes we never want to copy into the JSON payload (the
# meaningful ones are already mapped explicitly below).
_RESERVED = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename", "funcName",
    "levelname", "levelno", "lineno", "message", "module", "msecs", "msg", "name",
    "pathname", "process", "processName", "relativeCreated", "stack_info",
    "taskName", "thread", "threadName",
}


class _JsonFormatter(logging.Formatter):
    def __init__(self, service: str):
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": self.service,
            "correlation_id": getattr(record, "correlation_id", "none"),
            "message": record.getMessage(),
        }
        # Merge any structured context passed via `extra=`.
        for key, value in record.__dict__.items():
            if key not in _RESERVED and key not in payload:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # default=str so ObjectId / datetime / bytes never blow up a log call.
        return json.dumps(payload, default=str)


class _Adapter:
    """Thin wrapper so call sites can pass arbitrary structured fields as kwargs
    (the stdlib Logger only accepts a fixed set), routed through `extra`."""

    def __init__(self, logger: logging.Logger):
        self._logger = logger

    def _emit(self, level: int, message: str, exc_info=False, **fields):
        self._logger.log(level, message, extra=fields, exc_info=exc_info)

    def debug(self, message, **fields):
        self._emit(logging.DEBUG, message, **fields)

    def info(self, message, **fields):
        self._emit(logging.INFO, message, **fields)

    def warning(self, message, **fields):
        self._emit(logging.WARNING, message, **fields)

    def error(self, message, **fields):
        self._emit(logging.ERROR, message, **fields)

    def exception(self, message, **fields):
        self._emit(logging.ERROR, message, exc_info=True, **fields)


def get_logger(service: str) -> _Adapter:
    logger = logging.getLogger(service)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter(service))
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return _Adapter(logger)
