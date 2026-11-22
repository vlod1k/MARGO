"""Gmail HTTPS delivery; recovery secrets must never be logged or returned by the API."""
import base64
import logging
import os
from email.message import EmailMessage
from functools import partial

import httpx
import requests
from google.auth.exceptions import RefreshError
from google.auth.transport.requests import Request as GoogleRequest
from google.oauth2.credentials import Credentials

logger = logging.getLogger(__name__)
GMAIL_SEND_SCOPE = 'https://www.googleapis.com/auth/gmail.send'
GMAIL_TOKEN_URI = 'https://oauth2.googleapis.com/token'
GMAIL_ENV = ('MARGO_GMAIL_CLIENT_ID', 'MARGO_GMAIL_CLIENT_SECRET',
             'MARGO_GMAIL_REFRESH_TOKEN', 'MARGO_MAIL_FROM')


def recovery_available():
    return all(os.getenv(name, '').strip() for name in GMAIL_ENV)


def send_password_reset(email, token):
    text = (
        'В приложении MARGO нажмите «Забыли пароль?», затем «У меня есть код».\n'
        'Вставьте этот одноразовый код и задайте новый пароль:\n\n'
        f'{token}\n\n'
        'Код действует 30 минут. Новый запрос отменяет предыдущий код.\n'
        'После восстановления все устройства выйдут из аккаунта.\n'
        'Если вы не запрашивали восстановление, проигнорируйте письмо.'
    )
    try:
        if not recovery_available():
            raise ValueError('Email API is not configured')
        credentials = Credentials(
            token=None,
            refresh_token=os.environ['MARGO_GMAIL_REFRESH_TOKEN'].strip(),
            client_id=os.environ['MARGO_GMAIL_CLIENT_ID'].strip(),
            client_secret=os.environ['MARGO_GMAIL_CLIENT_SECRET'].strip(),
            token_uri=GMAIL_TOKEN_URI,
            scopes=[GMAIL_SEND_SCOPE],
        )
        with requests.Session() as session:
            credentials.refresh(partial(GoogleRequest(session=session), timeout=15, allow_redirects=False))
        message = EmailMessage()
        message['From'] = os.environ['MARGO_MAIL_FROM'].strip()
        message['To'] = email
        message['Subject'] = 'MARGO — восстановление доступа'
        message.set_content(text)
        # Fixed HTTPS endpoint and disabled redirects keep credentials and recovery
        # codes from being forwarded to another host.
        with httpx.Client(timeout=15, follow_redirects=False, headers={
            'Authorization': 'Bearer ' + credentials.token,
            'User-Agent': 'MARGO/password-recovery',
        }) as client:
            response = client.post('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', json={
                'raw': base64.urlsafe_b64encode(message.as_bytes()).decode('ascii'),
            })
            response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        logger.error('Password recovery email delivery failed (HTTP %s); check Gmail API configuration', exc.response.status_code)
    except RefreshError:
        logger.error('Password recovery email delivery failed; reconnect Gmail OAuth credentials')
    except Exception:
        # Exceptions and provider responses can contain recipients, keys or codes.
        logger.error('Password recovery email delivery failed; check Gmail API configuration and connectivity')
