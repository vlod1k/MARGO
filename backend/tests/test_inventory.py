from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import create_engine, select, literal, JSON
from sqlalchemy.orm import Session

from app.catalog import seed_catalog
from app.database import Base
from app.inventory import inventory, HasTopics
from app.models import Article, Interaction, User
from app.services import get_today
from ingestion.replenish import expand, replenish
from conftest import account


@pytest.mark.parametrize('value,expected', [({}, False), (None, False), ([], False), ({'history': 1}, True)])
def test_only_nonempty_topic_objects_are_eligible(db, value, expected):
    assert db.scalar(select(HasTopics(literal(value, type_=JSON)))) is expected


@pytest.fixture
def db():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session
    engine.dispose()


def test_inventory_excludes_unavailable_unclassified_seen_and_known(db):
    seed_catalog(db)
    user = User(email='stock@example.com', password_hash='test', onboarded=True)
    db.add(user)
    db.flush()
    db.get(Article, 'aurora').available = False
    db.get(Article, 'bauhaus').classification_status = 'unclassified'
    db.get(Article, 'mycelium').topics = {}
    db.add(Interaction(user_id=user.id, article_id='antikythera', feedback='known', read_at='2026-01-01'))
    db.commit()
    assert inventory(db, user.id)['ru']['remaining'] == 112
    get_today(db, user)
    assert inventory(db, user.id)['ru'] == {'available': 113, 'remaining': 111, 'low': False}
    assert inventory(db, user.id)['en'] == {'available': 0, 'remaining': 0, 'low': True}


def test_exhaustion_then_refill_recovers_without_repeats(db):
    seed_catalog(db)
    user = User(email='exhaust@example.com', password_hash='test', onboarded=True)
    db.add(user)
    db.commit()
    start = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    assigned = {get_today(db, user, start + timedelta(days=i)).article_id for i in range(116)}
    with pytest.raises(HTTPException) as error:
        get_today(db, user, start + timedelta(days=116))
    assert error.value.detail['code'] == 'catalog_exhausted'
    assert error.value.detail['inventory']['ru']['remaining'] == 0
    db.add(Article(id='new', language='ru', title='New', summary='New text', url='https://ru.wikipedia.org/wiki/New',
                   topics={'history': 1}, classification_status='classified'))
    db.commit()
    assert get_today(db, user, start + timedelta(days=116)).article_id == 'new'
    assert len(assigned) == 116


class Wiki:
    def category(self, title):
        return {'title': title, 'pageid': 1000, 'ns': 14}

    def iter_pages(self, title):
        for i in range(1, 4):
            yield {'pageid': i, 'title': f'Page {i}'}

    def articles(self, titles):
        return {'query': {'pages': [dict(title=title, pageid=int(title.split()[-1]), ns=0,
                extract='A valid introduction. ' * 10, fullurl='https://en.wikipedia.org/wiki/' + title.replace(' ', '_'))
                for title in titles]}}


def test_expansion_advances_past_existing_pages_preserves_disabled_and_filters(db):
    wiki = Wiki()
    assert expand(db, wiki, 'en', limit=1)['created'] == 1
    first = db.get(Article, 'en-1')
    first.available = False
    db.commit()
    assert expand(db, wiki, 'en', limit=1)['created'] == 1
    assert db.get(Article, 'en-2') is not None
    assert not first.available
    assert first.classification_version == 'category-direct-v1'
    assert first.attribution['license'].endswith('/by-sa/4.0/')
    class InvalidWiki(Wiki):
        def articles(self, titles):
            data = super().articles(titles)
            data['query']['pages'][0]['pageprops'] = {'disambiguation': ''}
            return data
    assert expand(db, InvalidWiki(), 'en', limit=1)['created'] == 0
    assert db.get(Article, 'en-3') is None


def test_refill_failures_are_isolated_by_language(db):
    calls = []
    def broken(language, budget):
        calls.append(language)
        raise RuntimeError('offline')
    # Session context is supplied without closing the shared fixture session.
    from contextlib import nullcontext
    report = replenish(lambda: nullcontext(db), broken)
    assert calls == ['ru', 'en']
    assert all(item['status'] == 'error' for item in report.values())


def test_status_requires_auth_and_empty_catalog_is_structured(client):
    assert client.get('/api/catalog/status').status_code == 401
    headers = account(client)
    stock = client.get('/api/catalog/status', headers=headers).json()['languages']
    assert stock['ru']['available'] == stock['ru']['remaining'] == 116
    profile = client.get('/api/preferences', headers=headers).json()
    assert client.patch('/api/preferences', headers=headers, json={**profile, 'language': 'en'}).status_code == 200
    response = client.get('/api/recommendations/today', headers=headers)
    assert response.status_code == 404
    assert response.json()['detail']['code'] == 'catalog_empty'
