"""Rule-based Event field extraction from public Weibo status pages."""

from .event_weibo_extractor import EventFields, WeiboFetchError, extract_event, extract_event_from_text

__all__ = [
    "EventFields",
    "WeiboFetchError",
    "extract_event",
    "extract_event_from_text",
]
