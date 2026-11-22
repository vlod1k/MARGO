from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app import mailer, security
from app.database import get_db
from app.main import app
from app.models import PasswordReset
from conftest import account

NEW_PASSWORD = 'newpass8'


def database():
    return contextmanager(app.dependency_overrides[get_db])()


@pytest.fixture
def mailbox(monkeypatch):
    messages = []
    for name in ('MARGO_GMAIL_CLIENT_ID', 'MARGO_GMAIL_CLIENT_SECRET', 'MARGO_GMAIL_REFRESH_TOKEN'):
        monkeypatch.setenv(name, 'gmail_test_secret')
    monkeypatch.setenv('MARGO_MAIL_FROM', 'margo@example.com')
    monkeypatch.setattr(mailer, 'send_password_reset', lambda email, token: messages.append((email, token)))
    return messages


def login(client, password='correct-horse-123', email='reader@example.com'):
    return client.post('/api/auth/login', json={'email': email, 'password': password})


def request_code(client, email='reader@example.com'):
    return client.post('/api/auth/password/reset/request', json={'email': email})


def confirm(client, token, password=NEW_PASSWORD, email='reader@example.com'):
    return client.post('/api/auth/password/reset/confirm', json={'email': email, 'token': token, 'new_password': password})


def test_recovery_is_private_single_use_and_revokes_all_sessions(client, mailbox):
    first = account(client)
    other = account(client, 'other@example.com')
    second = {'Authorization': 'Bearer ' + login(client).json()['access_token']}
    known = request_code(client, 'READER@example.com')
    unknown = request_code(client, 'missing@example.com')
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()
    assert len(mailbox) == 1
    email, token = mailbox[0]
    assert email == 'reader@example.com'
    assert len(token) == 6 and token.isascii() and token.isdigit()
    assert token not in known.text
    with database() as db:
        reset = db.scalar(select(PasswordReset))
        assert reset.token_hash == security.password_reset_digest('reader@example.com', token)
        assert reset.attempts == 0
    assert confirm(client, token).status_code == 204
    assert confirm(client, token).status_code == 400
    for headers in (first, second):
        assert client.get('/api/auth/me', headers=headers).status_code == 401
    assert client.get('/api/auth/me', headers=other).status_code == 200
    assert login(client).status_code == 401
    assert login(client, NEW_PASSWORD).status_code == 200


def test_expiration_replacement_and_cooldown(client, mailbox):
    headers = account(client)
    request_code(client)
    first = mailbox[-1][1]
    assert request_code(client).status_code == 202
    assert len(mailbox) == 1
    with database() as db:
        reset = db.get(PasswordReset, security.password_reset_digest('reader@example.com', first))
        reset.created_at = (datetime.now(timezone.utc)-timedelta(minutes=2)).isoformat()
        db.commit()
    request_code(client)
    second = mailbox[-1][1]
    assert second != first
    assert confirm(client, first).status_code == 400
    with database() as db:
        reset = db.get(PasswordReset, security.password_reset_digest('reader@example.com', second))
        reset.expires_at = (datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()
        db.commit()
    assert confirm(client, second).status_code == 400
    assert confirm(client, '999999').status_code == 400
    assert login(client).status_code == 200
    assert client.get('/api/auth/me', headers=headers).status_code == 200


def test_change_requires_current_password_and_keeps_only_current_session(client, mailbox):
    headers = account(client)
    other = account(client, 'other@example.com')
    second = {'Authorization': 'Bearer ' + login(client).json()['access_token']}
    request_code(client)
    token = mailbox[-1][1]
    path = '/api/auth/password/change'
    body = {'current_password': 'wrong-password', 'new_password': NEW_PASSWORD}
    assert client.post(path, json=body).status_code == 401
    assert client.post(path, json=body, headers=headers).status_code == 400
    assert client.get('/api/auth/me', headers=second).status_code == 200
    body['current_password'] = 'correct-horse-123'
    assert client.post(path, json=body, headers=headers).status_code == 204
    assert client.get('/api/auth/me', headers=headers).status_code == 200
    assert client.get('/api/auth/me', headers=second).status_code == 401
    assert client.get('/api/auth/me', headers=other).status_code == 200
    assert confirm(client, token).status_code == 400
    assert login(client).status_code == 401
    assert login(client, NEW_PASSWORD).status_code == 200


def test_same_six_digit_code_is_scoped_to_email(client, mailbox, monkeypatch):
    account(client)
    account(client, 'other@example.com')
    monkeypatch.setattr('app.main.secrets.randbelow', lambda _: 12345)
    request_code(client)
    request_code(client, 'other@example.com')
    assert [code for _, code in mailbox] == ['012345', '012345']
    with database() as db:
        assert len(db.scalars(select(PasswordReset)).all()) == 2
    assert confirm(client, '012345', email='missing@example.com').status_code == 400
    assert confirm(client, '012345', email='READER@example.com').status_code == 204
    assert login(client, email='other@example.com').status_code == 200
    assert confirm(client, '012345', email='other@example.com').status_code == 204


def test_five_wrong_attempts_block_code_until_replacement(client, mailbox):
    account(client)
    request_code(client)
    token = mailbox[-1][1]
    wrong = '000000' if token != '000000' else '000001'
    for _ in range(5):
        assert confirm(client, wrong).status_code == 400
    with database() as db:
        reset = db.scalar(select(PasswordReset))
        assert reset.attempts == 5
        reset.created_at = (datetime.now(timezone.utc)-timedelta(minutes=2)).isoformat()
        db.commit()
    assert confirm(client, token).status_code == 400
    assert login(client).status_code == 200
    request_code(client)
    replacement = mailbox[-1][1]
    assert replacement != token
    for _ in range(4):
        wrong = '000000' if replacement != '000000' else '000001'
        assert confirm(client, wrong).status_code == 400
    assert confirm(client, replacement).status_code == 204


@pytest.mark.parametrize('code', ['12345', '1234567', 'abcdef', '１２３４５６', 'a'*43])
def test_only_six_ascii_digits_are_accepted(client, code):
    assert confirm(client, code).status_code == 422


def test_logout_others_is_scoped_and_repeatable(client):
    headers = account(client)
    other = account(client, 'other@example.com')
    second = {'Authorization': 'Bearer ' + login(client).json()['access_token']}
    path = '/api/auth/logout-others'
    assert client.post(path).status_code == 401
    for _ in range(2):
        assert client.post(path, headers=headers).status_code == 204
    assert client.get('/api/auth/me', headers=headers).status_code == 200
    assert client.get('/api/auth/me', headers=other).status_code == 200
    assert client.get('/api/auth/me', headers=second).status_code == 401
    assert client.post(path, headers=second).status_code == 401


def test_reset_cascades_on_account_deletion(client, mailbox):
    headers = account(client)
    request_code(client)
    token = mailbox[-1][1]
    assert client.delete('/api/account', headers=headers).status_code == 204
    with database() as db:
        assert db.get(PasswordReset, security.password_reset_digest('reader@example.com', token)) is None
    assert confirm(client, token).status_code == 400


def test_reset_unconfigured_and_delivery_failure_do_not_expose_accounts(client, monkeypatch, caplog):
    monkeypatch.delenv('MARGO_GMAIL_REFRESH_TOKEN', raising=False)
    assert request_code(client).status_code == 503
    account(client)
    for name in ('MARGO_GMAIL_CLIENT_ID', 'MARGO_GMAIL_CLIENT_SECRET', 'MARGO_GMAIL_REFRESH_TOKEN'):
        monkeypatch.setenv(name, 'gmail_test_secret')
    monkeypatch.setenv('MARGO_MAIL_FROM', 'margo@example.com')

    def unavailable_client(**kwargs):
        raise RuntimeError('Connection failed for reader@example.com with gmail_test_secret')

    monkeypatch.setattr(mailer, 'GoogleRequest', unavailable_client)
    assert request_code(client).status_code == 202
    assert 'delivery failed' in caplog.text
    assert 'reader@example.com' not in caplog.text
    assert 'gmail_test_secret' not in caplog.text


def test_validation_secrets_and_rate_limit(client, mailbox):
    secret = 'sensitive-' * 20
    response = client.post('/api/auth/password/reset/confirm', json={'email': 'reader@example.com', 'token': secret, 'new_password': secret})
    assert response.status_code == 422
    assert secret not in response.text
    assert response.headers['Cache-Control'] == 'no-store'
    assert confirm(client, 'a'*43, 'short').status_code == 422
    for _ in range(30):
        request_code(client)
    assert request_code(client).status_code == 429


