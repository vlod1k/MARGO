from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from sqlalchemy import select

from app.database import get_db
from app.main import app
from app.models import DeviceToken, DailyRecommendation, Interaction, Session, SyncOperation, User
from app import security
from conftest import account


@pytest.mark.parametrize('path', ['/api/auth/login', '/api/auth/register'])
def test_validation_does_not_echo_passwords(client, path):
    password = 'sensitive-password-' * 10
    response = client.post(path, json={'email': 'reader@example.com', 'password': password})
    assert response.status_code == 422
    assert password not in response.text
    assert all(set(error) == {'type', 'loc', 'msg'} for error in response.json()['detail'])
    assert response.headers['Cache-Control'] == 'no-store'


def test_private_responses_are_not_cacheable(client):
    registered = client.post('/api/auth/register', json={
        'email': 'reader@example.com', 'password': 'newpass8',
    })
    headers = {'Authorization': 'Bearer ' + registered.json()['access_token']}
    responses = [registered, client.get('/api/auth/me', headers=headers),
                 client.get('/api/account/export', headers=headers),
                 client.get('/api/auth/me'), client.post('/api/auth/logout', headers=headers)]
    for response in responses:
        assert response.headers['Cache-Control'] == 'no-store'
        assert response.headers['Pragma'] == 'no-cache'


def test_unknown_account_also_verifies_password(client, monkeypatch):
    calls = []
    original = security.passwords.verify

    def verify(password, stored):
        calls.append(stored)
        return original(password, stored)

    monkeypatch.setattr(security.passwords, 'verify', verify)
    response = client.post('/api/auth/login', json={
        'email': 'missing@example.com', 'password': 'wrong-password',
    })
    assert response.status_code == 401
    assert calls == [security._dummy_password_hash]


def test_storage_isolation_and_account_cascade(client):
    a = account(client)
    b = account(client, 'other@example.com')
    a_id = client.get('/api/auth/me', headers=a).json()['id']
    b_id = client.get('/api/auth/me', headers=b).json()['id']
    operation_id = str(uuid4())
    for headers, value in [(a, True), (b, False)]:
        response = client.post('/api/sync/operations', headers=headers, json={'operations': [{
            'operation_id': operation_id, 'article_id': 'aurora',
            'field': 'saved', 'value': value, 'base_version': 0,
        }]})
        assert response.status_code == 200
        assert response.json()['results'][0]['interaction']['saved'] is value
        assert client.get('/api/recommendations/today', headers=headers).status_code == 200

    database = contextmanager(app.dependency_overrides[get_db])
    with database() as db:
        user = db.get(User, a_id)
        assert user.password_hash.startswith('$argon2id$')
        assert user.password_hash != 'correct-horse-123'
        token = a['Authorization'].removeprefix('Bearer ')
        assert db.get(Session, token) is None
        assert db.get(Session, security.digest(token)).user_id == a_id
        device = DeviceToken(user_id=a_id, platform='android', token='private-device-token')
        db.add(device)
        db.commit()
        device_id = device.id

    assert client.delete('/api/devices/' + device_id, headers=b).status_code == 204
    with database() as db:
        assert db.get(DeviceToken, device_id) is not None

    snapshot = client.get('/api/account/export', headers=b).json()
    assert snapshot['profile']['id'] == b_id
    assert snapshot['interactions'][0]['saved'] is False
    assert 'password_hash' not in snapshot['profile']
    assert client.delete('/api/account', headers=a).status_code == 204
    with database() as db:
        assert db.get(User, a_id) is None
        for model in (Session, Interaction, DailyRecommendation, SyncOperation, DeviceToken):
            assert db.scalar(select(model).where(model.user_id == a_id)) is None
        assert db.get(User, b_id) is not None
        assert db.get(SyncOperation, (b_id, operation_id)) is not None
    assert client.get('/api/auth/me', headers=a).status_code == 401
    assert client.get('/api/account/export', headers=b).json() == snapshot


def test_expired_session_cannot_read_data(client):
    headers = account(client)
    token = headers['Authorization'].removeprefix('Bearer ')
    with contextmanager(app.dependency_overrides[get_db])() as db:
        session = db.get(Session, security.digest(token))
        session.expires_at = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        db.commit()
    assert client.get('/api/account/export', headers=headers).status_code == 401
