from datetime import datetime, timedelta, timezone
from uuid import uuid4
import pytest
from conftest import account

def operation(article,field,value,version=0,id=None):
    return {'operation_id':id or str(uuid4()),'article_id':article,'field':field,'value':value,'base_version':version}

def test_private_endpoints_require_authentication(client):
    for path in ['/api/auth/me','/api/topics','/api/recommendations/today','/api/library','/api/statistics','/api/account/export']:
        assert client.get(path).status_code==401

def test_registration_login_logout_and_account_deletion(client):
    h=account(client)
    assert client.get('/api/auth/me',headers=h).status_code==200
    assert client.post('/api/auth/login',json={'email':'reader@example.com','password':'wrong-password'}).status_code==401
    other=client.post('/api/auth/login',json={'email':'reader@example.com','password':'correct-horse-123'}).json()
    second={'Authorization':'Bearer '+other['access_token']}
    client.get('/api/recommendations/today',headers=h)
    assert client.post('/api/auth/logout',headers=h).status_code==204
    assert client.get('/api/auth/me',headers=h).status_code==401
    assert client.delete('/api/account',headers=second).status_code==204
    assert client.get('/api/auth/me',headers=second).status_code==401
    assert client.post('/api/auth/login',json={'email':'reader@example.com','password':'correct-horse-123'}).status_code==401

def test_daily_is_fixed_after_preferences_and_vote(client):
    h=account(client)
    first=client.get('/api/recommendations/today',headers=h).json()
    p=client.get('/api/preferences',headers=h).json()
    response=client.patch('/api/preferences',headers=h,json={**p,'interests':['space'],'version':p['version']})
    assert response.status_code==200,response.text
    client.post('/api/sync/operations',headers=h,json={'operations':[operation(first['article']['id'],'feedback','liked')]})
    assert client.get('/api/recommendations/today',headers=h).json()==first

def test_retry_is_idempotent_and_votes_are_replaced(client):
    h=account(client)
    op=operation('antikythera','feedback','liked')
    body={'operations':[op]}
    first=client.post('/api/sync/operations',headers=h,json=body).json()
    again=client.post('/api/sync/operations',headers=h,json=body).json()
    assert first['profile']['weights']==again['profile']['weights']
    assert again['interactions'][0]['field_versions']['feedback']==1
    assert abs(again['profile']['weights']['history']-.25)<1e-9
    replaced=client.post('/api/sync/operations',headers=h,json={'operations':[operation('antikythera','feedback','uninterested',1)]}).json()
    assert abs(replaced['profile']['weights']['history']-.15)<1e-9
    collision={**op,'value':'known'}
    assert client.post('/api/sync/operations',headers=h,json={'operations':[collision]}).status_code==409

def test_two_devices_conflicts_and_independent_fields(client):
    h=account(client)
    a=client.post('/api/sync/operations',headers=h,json={'operations':[operation('aurora','saved',True)]}).json()
    assert a['results'][0]['status']=='applied'
    b=client.post('/api/sync/operations',headers=h,json={'operations':[operation('aurora','saved',False)]}).json()
    assert b['results'][0]['status']=='conflict'
    vote=client.post('/api/sync/operations',headers=h,json={'operations':[operation('aurora','feedback','difficult')]}).json()
    assert vote['results'][0]['status']=='applied'
    assert vote['interactions'][0]['saved'] is True
    assert vote['profile']['weights']['physics']==.2

def test_data_isolation_and_preference_conflict(client):
    a=account(client);b=account(client,'other@example.com')
    client.post('/api/sync/operations',headers=a,json={'operations':[operation('aurora','saved',True)]})
    assert client.get('/api/library',headers=b).json()['interactions']==[]
    p=client.get('/api/preferences',headers=a).json()
    assert client.patch('/api/preferences',headers=a,json=p).status_code==200
    assert client.patch('/api/preferences',headers=a,json=p).status_code==409
    assert client.patch('/api/preferences',headers=b,json={**p,'timezone':'Not/AZone'}).status_code==422

def test_offline_batch_replay_and_read_statistics(client):
    h=account(client)
    ops=[operation('aurora','saved',True),operation('aurora','feedback','known'),operation('aurora','read',True)]
    for _ in range(2):
        result=client.post('/api/sync/operations',headers=h,json={'operations':ops})
        assert result.status_code==200,result.text
    assert client.get('/api/statistics',headers=h).json()['read_count']==1
    assert client.get('/api/recommendations/today',headers=h).json()['article']['id']!='aurora'

def test_read_can_be_removed_and_retried_without_restoring_it(client):
    h=account(client)
    def send(op):
        response=client.post('/api/sync/operations',headers=h,json={'operations':[op]})
        assert response.status_code==200,response.text
        return response.json()
    mark=operation('aurora','read',True)
    send(mark)
    assert client.get('/api/statistics',headers=h).json()['read_count']==1
    clear=operation('aurora','read',False,1)
    for _ in range(2):
        result=send(clear)
        assert result['results'][0]['status']=='applied'
        assert result['interactions'][0]['read_at'] is None
        assert result['interactions'][0]['field_versions']['read']==2
    # A delayed replay of an already processed mark must not resurrect the state.
    assert send(mark)['interactions'][0]['read_at'] is None
    assert client.get('/api/statistics',headers=h).json()['read_count']==0
    stale=send(operation('aurora','read',True,1))
    assert stale['results'][0]['status']=='conflict'
    assert stale['interactions'][0]['read_at'] is None
    assert send(operation('aurora','read',True,2))['interactions'][0]['read_at'] is not None


def test_offline_read_dates_survive_batch_retries_conflicts_and_rereading(client):
    h=account(client)
    first={**operation('aurora','read',True),'read_at':'2026-01-02T01:30:00+03:00'}
    second={**operation('antikythera','read',True),'read_at':'2026-01-04T12:00:00Z'}
    def send(ops):
        response=client.post('/api/sync/operations',headers=h,json={'operations':ops})
        assert response.status_code==200,response.text
        return response.json()
    for _ in range(2):
        result=send([first,second])
        dates={i['article_id']:i['read_at'] for i in result['interactions']}
        assert dates=={'aurora':'2026-01-01T22:30:00+00:00','antikythera':'2026-01-04T12:00:00+00:00'}
        assert sorted(client.get('/api/statistics',headers=h).json()['reading_dates'])==sorted(dates.values())
    collision={**first,'read_at':'2026-01-05T12:00:00Z'}
    assert client.post('/api/sync/operations',headers=h,json={'operations':[collision]}).status_code==409
    repeated={**operation('aurora','read',True,1),'read_at':'2026-01-06T12:00:00Z'}
    assert send([repeated])['results'][0]['interaction']['read_at']==dates['aurora']
    stale={**operation('aurora','read',True,1),'read_at':'2026-01-07T12:00:00Z'}
    assert send([stale])['results'][0]['status']=='conflict'
    send([operation('aurora','read',False,2)])
    reread={**operation('aurora','read',True,3),'read_at':'2026-01-08T12:00:00Z'}
    assert send([reread])['results'][0]['interaction']['read_at']=='2026-01-08T12:00:00+00:00'


@pytest.mark.parametrize('field,value,read_at',[
    ('read',True,'invalid'),
    ('read',True,'2026-01-02'),
    ('read',True,'2026-01-02T12:00:00'),
    ('read',True,'2026-02-30T12:00:00Z'),
    ('read',True,1760000000),
    ('read',True,'1760000000'),
    ('read',True,(datetime.now(timezone.utc)+timedelta(days=1)).isoformat()),
    ('read',False,'2026-01-02T12:00:00Z'),
    ('saved',True,'2026-01-02T12:00:00Z'),
    ('feedback','liked','2026-01-02T12:00:00Z'),
])
def test_invalid_read_time_rejects_entire_batch(client,field,value,read_at):
    h=account(client)
    valid=operation('antikythera','saved',True)
    invalid={**operation('aurora',field,value),'read_at':read_at}
    response=client.post('/api/sync/operations',headers=h,json={'operations':[valid,invalid]})
    assert response.status_code==422,response.text
    assert client.get('/api/library',headers=h).json()['interactions']==[]


def test_read_time_allows_small_clock_skew(client):
    h=account(client)
    op={**operation('aurora','read',True),'read_at':(datetime.now(timezone.utc)+timedelta(minutes=4)).isoformat()}
    assert client.post('/api/sync/operations',headers=h,json={'operations':[op]}).status_code==200

def test_invalid_sync_batch_rolls_back_all_previous_actions(client):
    h=account(client)
    valid=operation('aurora','saved',True)
    invalid=operation('missing-article','read',True)
    response=client.post('/api/sync/operations',headers=h,json={'operations':[valid,invalid]})
    assert response.status_code==404
    assert client.get('/api/library',headers=h).json()['interactions']==[]
    retry=client.post('/api/sync/operations',headers=h,json={'operations':[valid]})
    assert retry.status_code==200
    assert retry.json()['results'][0]['status']=='applied'
