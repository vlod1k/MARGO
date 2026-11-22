import base64
import json
from email import policy
from email.parser import BytesParser
from types import SimpleNamespace
from urllib.parse import parse_qs

import httpx
import pytest

from app import mailer

EMAIL = 'reader@example.com'
TOKEN = '012345'
KEY = 'gmail_access_secret'
CLIENT_SECRET = 'gmail_client_secret'
REFRESH_TOKEN = 'gmail_refresh_secret'


def refresh_request(url, method, body, headers, **kwargs):
    assert url == 'https://oauth2.googleapis.com/token'
    assert method == 'POST'
    assert kwargs['timeout'] == 15
    assert kwargs['allow_redirects'] is False
    data = parse_qs(body.decode())
    assert data['grant_type'] == ['refresh_token']
    assert data['refresh_token'] == [REFRESH_TOKEN]
    assert data['client_id'] == ['gmail_client_id']
    assert data['client_secret'] == [CLIENT_SECRET]
    assert data['scope'] == [mailer.GMAIL_SEND_SCOPE]
    return SimpleNamespace(status=200, data=json.dumps({
        'access_token': KEY, 'expires_in': 3600, 'token_type': 'Bearer',
    }).encode())


@pytest.fixture
def mail_api(monkeypatch):
    monkeypatch.setenv('MARGO_GMAIL_CLIENT_ID', 'gmail_client_id')
    monkeypatch.setenv('MARGO_GMAIL_CLIENT_SECRET', CLIENT_SECRET)
    monkeypatch.setenv('MARGO_GMAIL_REFRESH_TOKEN', REFRESH_TOKEN)
    monkeypatch.setenv('MARGO_MAIL_FROM', 'MARGO <sender@gmail.com>')
    monkeypatch.setattr(mailer, 'GoogleRequest', lambda **kwargs: refresh_request)
    original_client = httpx.Client

    def install(handler):
        monkeypatch.setattr(mailer.httpx, 'Client', lambda **kwargs: original_client(
            transport=httpx.MockTransport(handler), **kwargs))

    return install


def test_gmail_request_refreshes_oauth_and_sends_encoded_message(mail_api, caplog):
    requests = []

    def handler(request):
        requests.append(request)
        assert request.method == 'POST'
        assert str(request.url) == 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'
        assert request.headers['Authorization'] == 'Bearer ' + KEY
        assert request.headers['User-Agent'].startswith('MARGO/')
        assert request.headers['Content-Type'] == 'application/json'
        assert request.extensions['timeout']['read'] == 15
        payload = json.loads(request.content)
        message = BytesParser(policy=policy.default).parsebytes(base64.urlsafe_b64decode(payload['raw']))
        assert message['From'] == 'MARGO <sender@gmail.com>'
        assert message['To'] == EMAIL
        assert message['Subject'] == 'MARGO — восстановление доступа'
        assert TOKEN in message.get_content()
        assert '30 минут' in message.get_content()
        for secret in (KEY, CLIENT_SECRET, REFRESH_TOKEN):
            assert secret not in message.as_string()
        return httpx.Response(200, json={'id': 'message-id'})

    mail_api(handler)
    assert mailer.recovery_available()
    mailer.send_password_reset(EMAIL, TOKEN)
    assert len(requests) == 1
    assert not caplog.text


@pytest.mark.parametrize('status', [400, 401, 403, 429, 500])
def test_provider_errors_do_not_log_response_contents(mail_api, caplog, status):
    def handler(request):
        return httpx.Response(status, json={'message': f'{EMAIL} {TOKEN} {KEY}'})

    mail_api(handler)
    mailer.send_password_reset(EMAIL, TOKEN)
    assert f'HTTP {status}' in caplog.text
    for secret in (EMAIL, TOKEN, KEY, CLIENT_SECRET, REFRESH_TOKEN):
        assert secret not in caplog.text


def test_redirect_does_not_forward_recovery_secrets(mail_api, caplog):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(307, headers={'Location': 'https://another.example/mail'})

    mail_api(handler)
    mailer.send_password_reset(EMAIL, TOKEN)
    assert len(requests) == 1
    assert 'HTTP 307' in caplog.text


def test_timeout_is_handled_without_logging_secrets(mail_api, caplog):
    def handler(request):
        raise httpx.ReadTimeout(f'{EMAIL} {TOKEN} {KEY}', request=request)

    mail_api(handler)
    mailer.send_password_reset(EMAIL, TOKEN)
    assert 'delivery failed' in caplog.text
    for secret in (EMAIL, TOKEN, KEY, CLIENT_SECRET, REFRESH_TOKEN):
        assert secret not in caplog.text


@pytest.mark.parametrize('variable', mailer.GMAIL_ENV)
@pytest.mark.parametrize('value', ['', '   '])
def test_missing_configuration_disables_delivery(mail_api, monkeypatch, variable, value, caplog):
    def handler(request):
        pytest.fail('Unconfigured email delivery must not make a network request')

    mail_api(handler)
    monkeypatch.setenv(variable, value)
    assert not mailer.recovery_available()
    mailer.send_password_reset(EMAIL, TOKEN)
    assert 'delivery failed' in caplog.text


def test_revoked_oauth_does_not_send_or_expose_credentials(mail_api, monkeypatch, caplog):
    def handler(request):
        pytest.fail('An OAuth failure must not send an email')

    def revoked(*args, **kwargs):
        return SimpleNamespace(status=400, data=json.dumps({
            'error': 'invalid_grant', 'error_description': f'{EMAIL} {TOKEN} {REFRESH_TOKEN}',
        }).encode())

    mail_api(handler)
    monkeypatch.setattr(mailer, 'GoogleRequest', lambda **kwargs: revoked)
    mailer.send_password_reset(EMAIL, TOKEN)
    assert 'reconnect Gmail OAuth' in caplog.text
    for secret in (EMAIL, TOKEN, KEY, CLIENT_SECRET, REFRESH_TOKEN):
        assert secret not in caplog.text
