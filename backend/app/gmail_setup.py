"""One-time, local OAuth consent for the server's Gmail sender (no emails sent)."""
import argparse
import json
import os
from pathlib import Path

from pydantic import EmailStr, TypeAdapter

from .mailer import GMAIL_SEND_SCOPE, GMAIL_TOKEN_URI


def connect(client_secrets: Path, sender: str, output: Path):
    from google_auth_oauthlib.flow import InstalledAppFlow

    sender = str(TypeAdapter(EmailStr).validate_python(sender))
    if output.exists():
        raise ValueError('Output file already exists; use a new --output path')
    config = json.loads(client_secrets.read_text(encoding='utf-8'))
    installed = config.get('installed', {})
    if (installed.get('auth_uri') != 'https://accounts.google.com/o/oauth2/auth'
            or installed.get('token_uri') != GMAIL_TOKEN_URI):
        raise ValueError('Download an OAuth client JSON of type Desktop app from Google Cloud')
    flow = InstalledAppFlow.from_client_config(
        config, scopes=[GMAIL_SEND_SCOPE], autogenerate_code_verifier=True,
    )
    credentials = flow.run_local_server(
        host='127.0.0.1', port=0, timeout_seconds=180,
        authorization_prompt_message='',
        success_message='Gmail connected. You may close this window.',
        prompt='consent', access_type='offline', login_hint=sender,
    )
    if (not credentials.refresh_token or not credentials.has_scopes([GMAIL_SEND_SCOPE])
            or (credentials.granted_scopes is not None and GMAIL_SEND_SCOPE not in credentials.granted_scopes)):
        raise ValueError('Offline Gmail sending permission was not granted; reconnect the account')
    values = {
        'MARGO_GMAIL_CLIENT_ID': credentials.client_id,
        'MARGO_GMAIL_CLIENT_SECRET': credentials.client_secret,
        'MARGO_GMAIL_REFRESH_TOKEN': credentials.refresh_token,
        'MARGO_MAIL_FROM': f'MARGO <{sender}>',
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation avoids accidentally overwriting existing credentials.
    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as stream:
        for name, value in values.items():
            stream.write(f'{name}={json.dumps(value)}\n')


def main():
    parser = argparse.ArgumentParser(description='Connect a Gmail sender using browser OAuth consent')
    parser.add_argument('--client-secrets', required=True, type=Path)
    parser.add_argument('--sender', required=True, help='The Gmail address you will authorize in the browser')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / '.secrets' / 'gmail.env')
    args = parser.parse_args()
    try:
        connect(args.client_secrets, args.sender, args.output)
    except Exception:
        # OAuth exceptions may contain tokens or authorization codes.
        parser.exit(1, 'Gmail setup failed. Check the Desktop app JSON, consent, and output path. No credentials were printed.\n')
    print(f'Gmail connected. Copy the settings from {args.output} into the server .env; do not share this file.')


if __name__ == '__main__':
    main()
