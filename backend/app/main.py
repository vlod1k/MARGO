import os
import threading
import time
import secrets
from datetime import datetime, timedelta, timezone
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from uuid import UUID
from fastapi import FastAPI, Depends, HTTPException, Query, BackgroundTasks
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy import select, delete, text, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session as DBSession
from .database import Base, engine, get_db, SessionLocal
from .models import User, Session, PasswordReset, Article, Interaction, DailyRecommendation, DeviceToken
from .catalog import TOPICS, seed_catalog
from .security import current_user, passwords, issue_session, bearer, digest, verify_login_password, password_reset_digest
from .schemas import Credentials, Registration, Preferences, SyncRequest, Operation, Vote, SaveRequest, DeviceRequest, PasswordResetRequest, PasswordResetConfirm, PasswordChange
from . import mailer
from .services import profile_json, article_json, get_today, recommendation_json, apply_operation, sync_snapshot
from fastapi import Request
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from .inventory import inventory

@asynccontextmanager
async def lifespan(app):
    # Schema changes in production are applied via Alembic before startup.
    if os.getenv('MARGO_AUTO_INIT',os.getenv('THOTH_AUTO_INIT','false')).lower()=='true':
        Base.metadata.create_all(engine)
        with SessionLocal() as db: seed_catalog(db)
    yield

app=FastAPI(title='MARGO API',version='0.3.0',lifespan=lifespan)

@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    # Validation inputs/context can contain passwords, tokens or personal data.
    errors = [{key: error[key] for key in ('type', 'loc', 'msg')} for error in exc.errors()]
    return JSONResponse(status_code=422, content={'detail': errors})

@app.middleware('http')
async def private_response_headers(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith('/api/'):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
    return response

app.mount('/updates', StaticFiles(directory=os.getenv('MARGO_RELEASES_DIR', str(Path(__file__).resolve().parent.parent / 'releases')), check_dir=False), name='updates')
DB=Depends(get_db)
AUTH=Depends(current_user)

# Local MVP throttling. Use an edge/shared rate limiter for a multi-worker deployment.
_auth_attempts=defaultdict(deque)
_auth_lock=threading.Lock()
def auth_limit(request:Request):
    host=request.client.host if request.client else 'unknown'
    instant=time.monotonic()
    with _auth_lock:
        for key in list(_auth_attempts):
            if not _auth_attempts[key] or _auth_attempts[key][-1]<instant-60: del _auth_attempts[key]
        attempts=_auth_attempts[host]
        while attempts and attempts[0]<instant-60:attempts.popleft()
        if len(attempts)>=30:raise HTTPException(429,'Слишком много попыток. Подождите минуту.')
        attempts.append(instant)

@app.get('/health')
def health(db:DBSession=DB):
    try:
        db.execute(text('SELECT 1'))
        # A reachable server with an absent application schema is not ready.
        db.execute(select(User.id).limit(1))
    except SQLAlchemyError:
        return JSONResponse(status_code=503, content={'status': 'unavailable', 'database': 'error'},
                            headers={'Cache-Control': 'no-store'})
    return JSONResponse(content={'status': 'ok', 'database': 'ok'},
                        headers={'Cache-Control': 'no-store'})

@app.post('/api/auth/register',status_code=201,dependencies=[Depends(auth_limit)])
def register(body:Registration,db:DBSession=DB):
    email=str(body.email).lower()
    user=User(email=email,password_hash=passwords.hash(body.password),name=body.name)
    db.add(user)
    try: db.commit()
    except IntegrityError:
        db.rollback();raise HTTPException(409,'Этот адрес уже зарегистрирован')
    return issue_session(db,user)

@app.post('/api/auth/login',dependencies=[Depends(auth_limit)])
def login(body:Credentials,db:DBSession=DB):
    user=db.scalar(select(User).where(User.email==str(body.email).lower()).with_for_update())
    if not verify_login_password(body.password,user): raise HTTPException(401,'Неверный адрес или пароль')
    return issue_session(db,user)

@app.post('/api/auth/logout',status_code=204)
def logout(user:User=AUTH,credentials:HTTPAuthorizationCredentials=Depends(bearer),db:DBSession=DB):
    db.execute(delete(Session).where(Session.token_hash==digest(credentials.credentials)));db.commit()

def locked_account(db, user_id):
    return db.scalar(select(User).where(User.id==user_id).with_for_update().execution_options(populate_existing=True))


@app.post('/api/auth/password/reset/request', status_code=202, dependencies=[Depends(auth_limit)])
def request_password_reset(body:PasswordResetRequest, tasks:BackgroundTasks, db:DBSession=DB):
    if not mailer.recovery_available():
        raise HTTPException(503, 'Восстановление временно недоступно. Обратитесь в поддержку.')
    instant = datetime.now(timezone.utc)
    user = db.scalar(select(User).where(User.email==str(body.email).lower()).with_for_update())
    if user:
        previous = db.scalar(select(PasswordReset).where(PasswordReset.user_id==user.id))
        # Per-account cooldown also covers requests from different IPs.
        if not previous or previous.created_at <= (instant-timedelta(minutes=1)).isoformat():
            db.execute(delete(PasswordReset).where(PasswordReset.user_id==user.id))
            token = f'{secrets.randbelow(1_000_000):06d}'
            # A replacement must invalidate even a coincidentally repeated code.
            while previous and password_reset_digest(user.email, token) == previous.token_hash:
                token = f'{secrets.randbelow(1_000_000):06d}'
            db.add(PasswordReset(token_hash=password_reset_digest(user.email, token), user_id=user.id,
                                created_at=instant.isoformat(), expires_at=(instant+timedelta(minutes=30)).isoformat()))
            db.commit()
            tasks.add_task(mailer.send_password_reset, user.email, token)
    return {'message': 'Если аккаунт существует, письмо с кодом восстановления будет отправлено. Проверьте также папку «Спам».'}


@app.post('/api/auth/password/reset/confirm', status_code=204, dependencies=[Depends(auth_limit)])
def confirm_password_reset(body:PasswordResetConfirm, db:DBSession=DB):
    user = db.scalar(select(User).where(User.email==str(body.email).lower()).with_for_update())
    reset = db.scalar(select(PasswordReset).where(PasswordReset.user_id==user.id)) if user else None
    instant = datetime.now(timezone.utc).isoformat()
    if not reset or reset.expires_at <= instant or reset.attempts >= 5:
        raise HTTPException(400, 'Код недействителен или истёк. Запросите новый.')
    token_hash = password_reset_digest(user.email, body.token)
    if not secrets.compare_digest(token_hash, reset.token_hash):
        # Persist the account-wide budget; changing IP or restarting cannot reset it.
        db.execute(update(PasswordReset).where(
            PasswordReset.token_hash==reset.token_hash,
            PasswordReset.attempts<5).values(attempts=PasswordReset.attempts+1))
        db.commit()
        raise HTTPException(400, 'Код недействителен или истёк. Запросите новый.')
    # Conditional consumption makes the code single-use, including concurrent requests.
    consumed = db.execute(delete(PasswordReset).where(
        PasswordReset.token_hash==token_hash,
        PasswordReset.expires_at>instant,
        PasswordReset.attempts<5))
    if not user or consumed.rowcount != 1:
        db.rollback()
        raise HTTPException(400, 'Код недействителен или истёк. Запросите новый.')
    user.password_hash = passwords.hash(body.new_password)
    db.execute(delete(Session).where(Session.user_id==user.id))
    db.commit()


@app.post('/api/auth/password/change', status_code=204, dependencies=[Depends(auth_limit)])
def change_password(body:PasswordChange, user:User=AUTH,
                    credentials:HTTPAuthorizationCredentials=Depends(bearer), db:DBSession=DB):
    user = locked_account(db, user.id)
    session = db.get(Session, digest(credentials.credentials), populate_existing=True)
    if not user or not session or session.expires_at <= datetime.now(timezone.utc).isoformat():
        raise HTTPException(401, 'Сессия истекла или отозвана')
    if not verify_login_password(body.current_password, user):
        raise HTTPException(400, 'Текущий пароль указан неверно')
    user.password_hash = passwords.hash(body.new_password)
    db.execute(delete(PasswordReset).where(PasswordReset.user_id==user.id))
    db.execute(delete(Session).where(Session.user_id==user.id, Session.token_hash!=session.token_hash))
    db.commit()


@app.post('/api/auth/logout-others', status_code=204, dependencies=[Depends(auth_limit)])
def logout_others(user:User=AUTH, credentials:HTTPAuthorizationCredentials=Depends(bearer), db:DBSession=DB):
    locked_account(db, user.id)
    token_hash = digest(credentials.credentials)
    session = db.get(Session, token_hash, populate_existing=True)
    if not session or session.expires_at <= datetime.now(timezone.utc).isoformat():
        raise HTTPException(401, 'Сессия истекла или отозвана')
    db.execute(delete(Session).where(Session.user_id==user.id, Session.token_hash!=token_hash))
    db.commit()

@app.get('/api/auth/me')
@app.get('/api/preferences')
def me(user:User=AUTH,db:DBSession=DB): return profile_json(db,user)

@app.get('/api/topics')
def topics(user:User=AUTH): return [{'slug':slug,'name':name} for slug,name in TOPICS.items()]

@app.get('/api/catalog/status')
def catalog_status(user:User=AUTH,db:DBSession=DB):
    return {'languages':inventory(db,user.id)}

@app.patch('/api/preferences')
def preferences(body:Preferences,user:User=AUTH,db:DBSession=DB):
    locked=db.execute(select(User).where(User.id==user.id).with_for_update().execution_options(populate_existing=True)).scalar_one()
    if body.version!=locked.preferences_version: raise HTTPException(409,'Профиль изменён на другом устройстве. Синхронизируйте его и повторите изменение.')
    for field in ['name','interests','language','timezone','reminder','notifications']: setattr(locked,field,getattr(body,field))
    locked.onboarded=True
    locked.preferences_version+=1;db.commit()
    return profile_json(db,locked)

@app.get('/api/recommendations/today')
def today(user:User=AUTH,db:DBSession=DB):
    try:
        item=get_today(db,user);db.commit()
    except IntegrityError:
        db.rollback();item=get_today(db,user);db.commit()
    return {**recommendation_json(db,item),'catalog':inventory(db,user.id)}

@app.get('/api/recommendations/history')
def history(user:User=AUTH,db:DBSession=DB):
    return sync_snapshot(db,user)['history']

@app.get('/api/articles/{article_id}')
def article(article_id:str,user:User=AUTH,db:DBSession=DB):
    item=db.get(Article,article_id)
    if not item: raise HTTPException(404,'Статья не найдена')
    return article_json(item)

def process(db,user,operations):
    db.execute(select(User).where(User.id==user.id).with_for_update()).scalar_one()
    try:
        result=[apply_operation(db,user,op) for op in operations];db.commit()
    except IntegrityError:
        db.rollback();raise HTTPException(409,'Параллельная синхронизация. Повторите запрос с теми же operation_id.')
    return result

@app.post('/api/sync/operations')
def sync(body:SyncRequest,user:User=AUTH,db:DBSession=DB):
    results=process(db,user,body.operations)
    return {'results':results,**sync_snapshot(db,user)}

@app.post('/api/articles/{article_id}/feedback')
def vote(article_id:str,body:Vote,user:User=AUTH,db:DBSession=DB):
    return process(db,user,[Operation(operation_id=body.operation_id,article_id=article_id,field='feedback',value=body.feedback,base_version=body.base_version)])[0]

@app.get('/api/library')
def library(user:User=AUTH,db:DBSession=DB): return sync_snapshot(db,user)

@app.post('/api/library/{article_id}')
def save(article_id:str,body:SaveRequest,user:User=AUTH,db:DBSession=DB):
    return process(db,user,[Operation(operation_id=body.operation_id,article_id=article_id,field='saved',value=True,base_version=body.base_version)])[0]

@app.delete('/api/library/{article_id}')
def unsave(article_id:str,operation_id:UUID,base_version:int=Query(ge=0),user:User=AUTH,db:DBSession=DB):
    return process(db,user,[Operation(operation_id=operation_id,article_id=article_id,field='saved',value=False,base_version=base_version)])[0]

@app.get('/api/statistics')
def statistics(user:User=AUTH,db:DBSession=DB):
    items=db.scalars(select(Interaction).where(Interaction.user_id==user.id,Interaction.read_at.is_not(None))).all()
    counts={}
    for item in items:
        for topic in db.get(Article,item.article_id).topics: counts[topic]=counts.get(topic,0)+1
    return {'read_count':len(items),'topics':counts,'reading_dates':[i.read_at for i in items]}

@app.post('/api/devices/register',status_code=501)
def register_device(body:DeviceRequest,user:User=AUTH):
    # Do not accept and silently discard tokens when no push provider exists.
    raise HTTPException(501,'Удалённые push-уведомления ещё не подключены; используйте локальные напоминания.')

@app.delete('/api/devices/{id}',status_code=204)
def remove_device(id:str,user:User=AUTH,db:DBSession=DB):
    db.execute(delete(DeviceToken).where(DeviceToken.id==id,DeviceToken.user_id==user.id));db.commit()

@app.get('/api/account/export')
def export(user:User=AUTH,db:DBSession=DB): return sync_snapshot(db,user)

@app.delete('/api/account',status_code=204)
def delete_account(user:User=AUTH,db:DBSession=DB):
    db.delete(user);db.commit()
