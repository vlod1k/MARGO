def test_first_recommendation_waits_for_interests(client):
    response=client.post('/api/auth/register',json={'email':'new@example.com','password':'correct-horse-123'})
    headers={'Authorization':'Bearer '+response.json()['access_token']}
    assert client.get('/api/recommendations/today',headers=headers).status_code==409
    profile=client.get('/api/preferences',headers=headers).json()
    assert profile['onboarded'] is False
    assert client.patch('/api/preferences',headers=headers,json={**profile,'interests':['space']}).status_code==200
    assert client.get('/api/recommendations/today',headers=headers).status_code==200
    assert len(client.get('/api/recommendations/history',headers=headers).json())==1
