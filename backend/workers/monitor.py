"""Run independently of the API and scheduler; public probes include the HTTPS edge."""
import json
import logging
import os
import time
from pathlib import Path
import httpx
from sqlalchemy import select
from app.database import SessionLocal
from app.inventory import inventory
from app.models import User
from .alerts import Alerts
from .status import status_dir


def check_api(url):
    try:
        response = httpx.get(url, timeout=8, follow_redirects=False)
        return response.status_code == 200 and response.json().get('database') == 'ok'
    except (httpx.HTTPError, ValueError):
        return False


def read_status(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def check_scheduler(alerts, now):
    heartbeat = read_status(status_dir() / 'heartbeat.json')
    alerts.check('scheduler', now - heartbeat.get('time', 0) > 120,
                 'Scheduler heartbeat (maximum age: 120s)')
    for job, maximum_age in [('assign_daily', 900), ('replenish', 90000)]:
        if job == 'replenish' and not (os.getenv('WIKIMEDIA_USER_AGENT') and
                os.getenv('MARGO_CATALOG_AUTO_REFILL', 'true').lower() == 'true'):
            continue
        status = read_status(status_dir() / f'{job}.json')
        alerts.check(f'job:{job}', not status.get('ok') or now - status.get('time', 0) > maximum_age,
                     f'{job}: failure, missed run or stale status')


def check_stock(alerts, factory=SessionLocal):
    threshold = int(os.getenv('MARGO_CATALOG_LOW_WATERMARK', '60'))
    with factory() as db:
        minima = {lang: entry['remaining'] for lang, entry in inventory(db).items()}
        for user in db.scalars(select(User).where(User.onboarded.is_(True))):
            remaining = inventory(db, user.id)[user.language]['remaining']
            minima[user.language] = min(minima[user.language], remaining)
    for language, remaining in minima.items():
        alerts.check(f'stock:{language}', remaining < threshold,
                     f'{language}: minimum remaining {remaining}; threshold {threshold}')


def cycle(alerts):
    alerts.check('api', not check_api(os.environ['MARGO_MONITOR_URL']), 'Public API /health')
    check_scheduler(alerts, time.time())
    try:
        check_stock(alerts)
        alerts.check('inventory-check', False, 'Inventory database query')
    except Exception:
        logging.exception('Inventory check failed')
        alerts.check('inventory-check', True, 'Unable to query inventory')
    backup = read_status(Path(os.getenv('MARGO_BACKUP_STATUS', '/backups/status.json')))
    alerts.check('backup', not backup.get('ok') or time.time() - backup.get('verified_at', 0) > 90000,
                 'Backup missing, failed or not restore-verified within 25 hours')


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    alerts = Alerts('/var/lib/margo/monitor/alerts.json')
    # Give scheduler and the initial backup a chance to start after a host reboot.
    time.sleep(60)
    while True:
        try:
            cycle(alerts)
        except Exception:
            logging.exception('Monitor cycle failed')
            alerts.check('monitor', True, 'Monitor cycle failed')
        else:
            alerts.check('monitor', False, 'Monitor cycle completed')
        time.sleep(60)
