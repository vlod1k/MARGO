import json
from unittest.mock import Mock
import pytest
from pathlib import Path
from sqlalchemy.exc import OperationalError
from app.database import get_db
from app.main import app
from workers.alerts import Alerts
from workers import backup, monitor, scheduler


def test_health_uses_database(client):
    response = client.get('/health')
    assert response.status_code == 200
    assert response.json() == {'status': 'ok', 'database': 'ok'}
    db = Mock()
    db.execute.side_effect = OperationalError('SELECT 1', {}, Exception('secret-password'))
    app.dependency_overrides[get_db] = lambda: db
    response = client.get('/health')
    assert response.status_code == 503
    assert 'secret-password' not in response.text
    assert response.headers['cache-control'] == 'no-store'


def test_alert_retries_deduplicates_persists_and_recovers(tmp_path):
    sender = Mock(side_effect=[False, True, True, True])
    clock = Mock(return_value=10000)
    path = tmp_path / 'alerts.json'
    alerts = Alerts(path, sender, clock)
    alerts.check('api', True, 'down')
    assert alerts.state == {}
    alerts.check('api', True, 'down')
    alerts = Alerts(path, sender, clock)
    alerts.check('api', True, 'down')
    assert sender.call_count == 2
    clock.return_value += 3601
    alerts.check('api', True, 'down')
    alerts.check('api', False, 'up')
    alerts.check('api', False, 'up')
    assert sender.call_count == 4
    assert 'RECOVERED' in sender.call_args.args[0]


def test_scheduler_detects_dead_process_failed_and_stale_jobs(tmp_path, monkeypatch):
    monkeypatch.setenv('MARGO_SCHEDULER_STATUS_DIR', str(tmp_path))
    monkeypatch.setenv('MARGO_CATALOG_AUTO_REFILL', 'false')
    alerts = Mock()
    monitor.check_scheduler(alerts, 10000)
    assert all(call.args[1] is True for call in alerts.check.call_args_list)
    (tmp_path / 'heartbeat.json').write_text(json.dumps({'time': 9999, 'ok': True}))
    (tmp_path / 'assign_daily.json').write_text(json.dumps({'time': 9999, 'ok': False}))
    alerts.reset_mock()
    monitor.check_scheduler(alerts, 10000)
    assert alerts.check.call_args_list[0].args[1] is False
    assert alerts.check.call_args_list[1].args[1] is True


def test_replenishment_errors_not_swallowed(monkeypatch):
    monkeypatch.setattr(scheduler, 'replenish', lambda: {'ru': {'status': 'error'}})
    record = Mock()
    monkeypatch.setattr(scheduler, 'record', record)
    with pytest.raises(RuntimeError):
        scheduler.run_replenish()
    record.assert_called_once_with('replenish', False)


def test_failed_restore_preserves_previous_backup_and_marks_failure(tmp_path, monkeypatch):
    previous = tmp_path / 'margo-previous.dump'
    previous.write_bytes(b'previous good backup')
    def dump(command, args, **kwargs):
        Path(args[-1].removeprefix('--file=')).write_bytes(b'broken')
    monkeypatch.setattr(backup, 'pg', dump)
    monkeypatch.setattr(backup, 'verify_dump', Mock(side_effect=ValueError('bad dump')))
    with pytest.raises(ValueError):
        backup.backup_once(tmp_path)
    assert previous.read_bytes() == b'previous good backup'
    assert not list(tmp_path.glob('*.partial'))
    assert json.loads((tmp_path / 'status.json').read_text())['ok'] is False


def test_restore_refuses_production_instance(monkeypatch):
    monkeypatch.setenv('PGHOST', 'db')
    monkeypatch.setenv('VERIFY_PGHOST', 'db')
    with pytest.raises(ValueError, match='separate'):
        backup.verify_dump('anything.dump')


def test_public_probe_rejects_old_fake_health_and_network_errors(monkeypatch):
    monkeypatch.setattr(monitor.httpx, 'get', lambda *a, **kw: Mock(
        status_code=200, json=lambda: {'status': 'ok'}))
    assert not monitor.check_api('https://example.com/health')
    monkeypatch.setattr(monitor.httpx, 'get', Mock(side_effect=monitor.httpx.ConnectError('down')))
    assert not monitor.check_api('https://example.com/health')
