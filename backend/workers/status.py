"""Scheduler writes one status file per job, read by the independent monitor."""
import os
import time
from pathlib import Path
from .alerts import atomic_json


def status_dir():
    return Path(os.getenv('MARGO_SCHEDULER_STATUS_DIR', '/var/lib/margo/scheduler'))


def record(job, ok):
    atomic_json(status_dir() / f'{job}.json', {'time': time.time(), 'ok': ok})


def heartbeat():
    record('heartbeat', True)
