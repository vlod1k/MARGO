import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pwdlib import PasswordHash
from sqlalchemy.orm import Session as DBSession
from .database import get_db
from .models import Session, User

passwords = PasswordHash.recommended()
# Unknown accounts must still pay the password verification cost.
_dummy_password_hash = passwords.hash(secrets.token_urlsafe(48))
bearer = HTTPBearer(auto_error=False)

def verify_login_password(password, user):
    valid = passwords.verify(password, user.password_hash if user else _dummy_password_hash)
    return user is not None and valid
def digest(token): return hashlib.sha256(token.encode()).hexdigest()

def password_reset_digest(email, token):
    return digest(f'password-reset:{email.lower()}:{token}')
def issue_session(db, user):
    token=secrets.token_urlsafe(48)
    db.add(Session(token_hash=digest(token),user_id=user.id,expires_at=(datetime.now(timezone.utc)+timedelta(days=30)).isoformat()))
    db.commit()
    return {'access_token':token,'token_type':'bearer','expires_in':30*86400,'user_id':user.id}

def current_user(credentials: HTTPAuthorizationCredentials | None=Depends(bearer),db:DBSession=Depends(get_db)):
    if credentials is None: raise HTTPException(401,'Требуется вход в аккаунт')
    session=db.get(Session,digest(credentials.credentials))
    if not session or session.expires_at <= datetime.now(timezone.utc).isoformat(): raise HTTPException(401,'Сессия истекла или отозвана')
    user=db.get(User,session.user_id)
    if not user: raise HTTPException(401,'Аккаунт удалён')
    return user
