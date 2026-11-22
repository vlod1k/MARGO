"""Persistent incident deduplication; failed deliveries are retried on the next check."""
import json
import logging
import os
import time
from pathlib import Path
from urllib.request import Request, build_opener, HTTPRedirectHandler


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value), encoding='utf-8')
    temporary.replace(path)


def deliver(message):
    webhook = os.getenv('MARGO_ALERT_WEBHOOK_URL', '')
    token = os.getenv('MARGO_ALERT_TELEGRAM_TOKEN', '')
    chat = os.getenv('MARGO_ALERT_TELEGRAM_CHAT_ID', '')
    if webhook:
        url, payload = webhook, {'text': message}
    elif token and chat:
        url = f'https://api.telegram.org/bot{token}/sendMessage'
        payload = {'chat_id': chat, 'text': message}
    else:
        logging.error('Alert delivery is not configured')
        return False
    if not url.startswith('https://'):
        logging.error('Alert destination must use HTTPS')
        return False
    try:
        request = Request(url, data=json.dumps(payload).encode(),
                          headers={'Content-Type': 'application/json'})
        with build_opener(NoRedirect()).open(request, timeout=10) as response:
            result = json.load(response) if token and not webhook else None
            if result is not None and not result.get('ok'):
                return False
        return True
    except Exception:
        # Exception URLs may contain Telegram tokens or webhook credentials.
        logging.error('Alert delivery failed; retrying on next check')
        return False


class Alerts:
    def __init__(self, path, sender=deliver, clock=time.time):
        self.path, self.sender, self.clock = Path(path), sender, clock
        try:
            self.state = json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            self.state = {}

    def check(self, key, problem, detail):
        previous = self.state.get(key, {})
        now = self.clock()
        if problem:
            if not previous.get('active') or now - previous.get('sent', 0) >= 3600:
                if self.sender(f'MARGO ALERT [{key}]: {detail}'):
                    self.state[key] = {'active': True, 'sent': now}
        elif previous.get('active'):
            if self.sender(f'MARGO RECOVERED [{key}]: {detail}'):
                self.state[key] = {'active': False, 'sent': now}
        atomic_json(self.path, self.state)
