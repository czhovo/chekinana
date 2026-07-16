# Event Weibo extractor

Standalone deterministic extraction of Event fields from public `weibo.com`
status URLs. It uses Weibo's anonymous visitor flow and public structured
status response. Visitor cookies remain in memory and are never printed or
persisted.

It does not use an LLM, browser automation, authenticated accounts, images, or
OCR. Missing fields are empty strings; `note` is always empty. Plain-text
ticket hints and Weibo lottery links are not treated as ticket URLs.

Different explicit full-date candidates are treated as ambiguous and leave
`date` empty. A literal value that is only a detailed street address is not
accepted as `livehouse`. The shared `parity_fixtures.json` corpus is also used
by the Cloudflare Worker port to keep both deterministic implementations
aligned.

Status URLs use the same strict raw-path, percent-decoding, UTF-8, decoded-user,
and ASCII status-ID contract as the Worker API. Invalid percent escapes and
replacement decoding are not accepted.

```sh
python3 scripts/event_weibo_extractor/event_weibo_extractor.py \
  'https://weibo.com/<public-user-id>/<public-status-id>'

python3 -m unittest discover -s scripts/event_weibo_extractor -p 'test_*.py'
```
