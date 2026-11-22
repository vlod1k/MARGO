"""Custom-format dumps, isolated restore verification, then retention. No production restore."""
import argparse
import hashlib
import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
from .alerts import atomic_json


def pg(command, args, *, verify=False, capture=False):
    prefix = 'VERIFY_' if verify else ''
    env = os.environ.copy()
    for name, default in [('PGHOST', 'db'), ('PGPORT', '5432'), ('PGUSER', 'thoth'),
                          ('PGPASSWORD', ''), ('PGDATABASE', 'thoth')]:
        env[name] = os.getenv(prefix + name, default)
    env['PGCONNECT_TIMEOUT'] = '5'
    return subprocess.run([command, *args], env=env, check=True, timeout=1800,
                          stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                          stderr=subprocess.PIPE, text=True).stdout


def verify_dump(path):
    source = (os.getenv('PGHOST', 'db'), os.getenv('PGPORT', '5432'))
    target = (os.environ['VERIFY_PGHOST'], os.getenv('VERIFY_PGPORT', '5432'))
    if source == target:
        raise ValueError('Restore verification must use a separate PostgreSQL instance')
    name = 'verify_' + uuid4().hex
    pg('createdb', ['--maintenance-db=postgres', '--template=template0', name], verify=True)
    try:
        pg('pg_restore', ['--exit-on-error', '--single-transaction', '--no-owner', '--no-acl',
                          '--dbname=' + name, str(path)], verify=True)
        # Application tables must be readable; indexes, FKs and constraints were recreated above.
        sql = """SELECT json_build_object(
          'revision', (SELECT version_num FROM alembic_version),
          'users', (SELECT count(*) FROM users),
          'articles', (SELECT count(*) FROM articles),
          'recommendations', (SELECT count(*) FROM daily_recommendations),
          'interactions', (SELECT count(*) FROM interactions),
          'sessions', (SELECT count(*) FROM sessions),
          'sync_operations', (SELECT count(*) FROM sync_operations));"""
        report = json.loads(pg('psql', ['-X', '--set=ON_ERROR_STOP=1', '-At', '-d', name,
                                       '-c', sql], verify=True, capture=True))
        if not report['revision']:
            raise ValueError('Missing schema revision')
        return report
    finally:
        pg('dropdb', ['--maintenance-db=postgres', '--if-exists', name], verify=True)


def backup_once(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid4().hex[:8]
    partial = directory / f'margo-{stamp}.partial'
    final = partial.with_suffix('.dump')
    try:
        pg('pg_dump', ['--format=custom', '--no-owner', '--no-acl', '--file=' + str(partial)])
        report = verify_dump(partial)
        with partial.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        partial.replace(final)
        result = {'ok': True, 'verified_at': time.time(), 'file': final.name,
                  'sha256': checksum, 'restored': report}
        atomic_json(final.with_suffix('.json'), result)
        atomic_json(directory / 'status.json', result)
        # Only rotate after a verified backup; a failed run never removes the last good copy.
        cutoff = time.time() - int(os.getenv('MARGO_BACKUP_RETENTION_DAYS', '14')) * 86400
        for old in directory.glob('margo-*.dump'):
            if old != final and old.stat().st_mtime < cutoff:
                old.unlink()
                old.with_suffix('.json').unlink(missing_ok=True)
        logging.info('Backup restore verified: %s; counts: %s', final.name, report)
        return result
    except Exception:
        atomic_json(directory / 'status.json', {'ok': False, 'failed_at': time.time()})
        raise
    finally:
        partial.unlink(missing_ok=True)


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--directory', default='/backups')
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(verify_dump(args.verify)))
    elif args.once:
        print(json.dumps(backup_once(args.directory)))
    else:
        while True:
            try:
                backup_once(args.directory)
            except Exception:
                # Do not log subprocess stderr, which may contain sensitive data.
                logging.error('Backup or restore verification failed; retry in 5 minutes')
                time.sleep(300)
            else:
                time.sleep(86400)
