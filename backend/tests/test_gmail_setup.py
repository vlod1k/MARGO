import json
import sys
from types import ModuleType

import pytest
from google.oauth2.credentials import Credentials

from app import gmail_setup
from app.mailer import GMAIL_SEND_SCOPE, GMAIL_TOKEN_URI


@pytest.fixture
def setup_flow(tmp_path, monkeypatch):
    client = tmp_path / 'client.json'
    client.write_text(json.dumps({'installed': {
        'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
        'token_uri': GMAIL_TOKEN_URI,
        'client_id': 'client-id', 'client_secret': 'client-secret',
    }}), encoding='utf-8')
    credentials = Credentials(
        token='temporary-access', refresh_token='private-refresh',
        client_id='client-id', client_secret='client-secret',
        scopes=[GMAIL_SEND_SCOPE], granted_scopes=[GMAIL_SEND_SCOPE],
    )
    calls = []

    class Flow:
        @classmethod
        def from_client_config(cls, config, **kwargs):
            assert kwargs == {'scopes': [GMAIL_SEND_SCOPE], 'autogenerate_code_verifier': True}
            assert 'installed' in config
            return cls()

        def run_local_server(self, **kwargs):
            calls.append(kwargs)
            assert kwargs['host'] == '127.0.0.1'
            assert kwargs['port'] == 0
            assert kwargs['timeout_seconds'] == 180
            assert kwargs['access_type'] == 'offline'
            assert kwargs['prompt'] == 'consent'
            assert kwargs['login_hint'] == 'sender@gmail.com'
            assert not kwargs['authorization_prompt_message']
            return credentials

    # The setup helper is optional in deployed API installations.
    package = ModuleType('google_auth_oauthlib')
    module = ModuleType('google_auth_oauthlib.flow')
    module.InstalledAppFlow = Flow
    monkeypatch.setitem(sys.modules, 'google_auth_oauthlib', package)
    monkeypatch.setitem(sys.modules, 'google_auth_oauthlib.flow', module)
    return client, credentials, calls


def test_setup_saves_server_settings_without_printing_tokens(setup_flow, tmp_path, capsys):
    client, _, calls = setup_flow
    output = tmp_path / 'secrets' / 'gmail.env'
    gmail_setup.connect(client, 'sender@gmail.com', output)
    assert len(calls) == 1
    settings = dict(line.split('=', 1) for line in output.read_text().splitlines())
    assert {key: json.loads(value) for key, value in settings.items()} == {
        'MARGO_GMAIL_CLIENT_ID': 'client-id',
        'MARGO_GMAIL_CLIENT_SECRET': 'client-secret',
        'MARGO_GMAIL_REFRESH_TOKEN': 'private-refresh',
        'MARGO_MAIL_FROM': 'MARGO <sender@gmail.com>',
    }
    assert capsys.readouterr() == ('', '')


def test_setup_preserves_existing_credentials(setup_flow, tmp_path):
    client, _, calls = setup_flow
    output = tmp_path / 'gmail.env'
    output.write_text('existing-settings', encoding='utf-8')
    with pytest.raises(ValueError, match='already exists'):
        gmail_setup.connect(client, 'sender@gmail.com', output)
    assert output.read_text() == 'existing-settings'
    assert not calls


@pytest.mark.parametrize('missing', ['refresh', 'scope'])
def test_setup_rejects_incomplete_consent(setup_flow, tmp_path, missing):
    client, credentials, _ = setup_flow
    if missing == 'refresh':
        credentials._refresh_token = None
    else:
        credentials._granted_scopes = ['openid']
    output = tmp_path / 'gmail.env'
    with pytest.raises(ValueError, match='not granted'):
        gmail_setup.connect(client, 'sender@gmail.com', output)
    assert not output.exists()


def test_setup_rejects_non_google_oauth_endpoints(setup_flow, tmp_path):
    client, _, calls = setup_flow
    client.write_text(json.dumps({'installed': {
        'auth_uri': 'https://another.example/authorize', 'token_uri': GMAIL_TOKEN_URI,
    }}), encoding='utf-8')
    with pytest.raises(ValueError, match='Desktop app'):
        gmail_setup.connect(client, 'sender@gmail.com', tmp_path / 'gmail.env')
    assert not calls


def test_cli_failure_does_not_print_oauth_exception(monkeypatch, capsys):
    def failed(*args):
        raise RuntimeError('private-refresh private-authorization-code')

    monkeypatch.setattr(gmail_setup, 'connect', failed)
    monkeypatch.setattr(sys, 'argv', ['gmail_setup', '--client-secrets', 'client.json', '--sender', 'sender@gmail.com'])
    with pytest.raises(SystemExit) as result:
        gmail_setup.main()
    assert result.value.code == 1
    captured = capsys.readouterr()
    assert 'setup failed' in captured.err
    assert 'private-' not in captured.out + captured.err
