import logging
import os
import time
from datetime import datetime, timezone
from apscheduler.schedulers.blocking import BlockingScheduler
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from app.database import SessionLocal
from app.models import User
from app.services import get_today
from ingestion.replenish import replenish
from apscheduler.events import EVENT_JOB_ERROR, EVENT_JOB_MISSED, EVENT_JOB_MAX_INSTANCES
from workers.status import record, heartbeat

logging.basicConfig(level=logging.INFO)
def assign_daily():
    failures = 0
    with SessionLocal() as db: ids=list(db.scalars(select(User.id).where(User.onboarded.is_(True))))
    for id in ids:
        with SessionLocal() as db:
            try:
                get_today(db,db.get(User,id));db.commit()
            except HTTPException as exc:
                db.rollback()
                if exc.status_code == 404:
                    logging.warning('Daily assignment skipped: catalog exhausted')
                else:
                    logging.exception('Assignment skipped for user %s',id)
                    failures += 1
            except SQLAlchemyError:
                db.rollback();logging.exception('Assignment skipped for user %s',id)
                failures += 1
    if failures:
        raise RuntimeError(f'Daily assignments failed: {failures}')


def run_assignment():
    try:
        assign_daily()
    except Exception:
        record('assign_daily', False)
        raise
    record('assign_daily', True)


def run_replenish():
    try:
        reports = replenish()
        if any(item['status'] == 'error' for item in reports.values()):
            raise RuntimeError('Catalog replenishment failed')
    except Exception:
        record('replenish', False)
        raise
    record('replenish', True)


def job_failed(event):
    record(event.job_id, False)

if __name__=='__main__':
    # Exactly one scheduler process; DB uniqueness is a second line of defense.
    scheduler=BlockingScheduler(timezone='UTC')
    scheduler.add_listener(job_failed, EVENT_JOB_ERROR | EVENT_JOB_MISSED | EVENT_JOB_MAX_INSTANCES)
    scheduler.add_job(heartbeat, 'interval', seconds=30, id='heartbeat', max_instances=1)
    scheduler.add_job(run_assignment,'interval',minutes=5,id='assign_daily',max_instances=1,coalesce=True,
                      next_run_time=datetime.now(timezone.utc))
    if os.getenv('MARGO_CATALOG_AUTO_REFILL', 'true').lower() == 'true':
        if os.getenv('WIKIMEDIA_USER_AGENT'):
            scheduler.add_job(run_replenish,'interval',hours=24,id='replenish',max_instances=1,coalesce=True,
                              next_run_time=datetime.now(timezone.utc))
        else:
            logging.warning('Catalog auto-refill disabled: set WIKIMEDIA_USER_AGENT with a real contact')
    heartbeat();scheduler.start()
