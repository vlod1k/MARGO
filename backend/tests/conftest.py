import os
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker
from app.database import Base, get_db
from app.main import app
from app.main import _auth_attempts
from app.catalog import seed_catalog

@pytest.fixture
def client(tmp_path):
    _auth_attempts.clear()
    url=os.getenv('TEST_DATABASE_URL','sqlite:///'+str(tmp_path/'test.db'))
    engine=create_engine(url,connect_args={'check_same_thread':False} if url.startswith('sqlite') else {})
    if not url.startswith('sqlite'):
        assert engine.url.database.endswith('_test'), 'Use a dedicated *_test database'
        Base.metadata.drop_all(engine)
    else:
        @event.listens_for(engine,'connect')
        def enable_fk(connection,_): connection.execute('PRAGMA foreign_keys=ON')
    Base.metadata.create_all(engine)
    factory=sessionmaker(bind=engine,expire_on_commit=False)
    with factory() as db: seed_catalog(db)
    def override():
        with factory() as db: yield db
    app.dependency_overrides[get_db]=override
    with TestClient(app) as client: yield client
    app.dependency_overrides.clear();engine.dispose()

def account(client,email='reader@example.com'):
    response=client.post('/api/auth/register',json={'email':email,'password':'correct-horse-123'})
    assert response.status_code==201,response.text
    headers={'Authorization':'Bearer '+response.json()['access_token']}
    profile=client.get('/api/preferences',headers=headers).json()
    configured=client.patch('/api/preferences',headers=headers,json=profile)
    assert configured.status_code==200,configured.text
    return headers
