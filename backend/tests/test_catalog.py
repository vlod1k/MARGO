from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select, func
from sqlalchemy.orm import Session

from app.catalog import TOPICS, seed_catalog
from app.curated import entries
from app.database import Base
from app.models import Article, Interaction, User
from app.services import get_today
from ingestion.curated import import_curated


@pytest.fixture
def db():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session
    engine.dispose()


def response(titles, **extra):
    return {'query': {'pages': [dict(title=title, pageid=i + 100, ns=0,
        extract='Wikipedia introduction ' + title,
        fullurl='https://en.wikipedia.org/wiki/' + title.replace(' ', '_'))
        for i, title in enumerate(titles)], **extra}}


def test_bundled_catalog_is_balanced_and_restart_safe(db):
    seed_catalog(db)
    assert db.scalar(select(func.count()).select_from(Article)) == 116
    for language in ('ru', 'en'):
        rows = list(entries(language))
        assert len({row['id'] for row in rows}) == 100
        assert len({row['title'] for row in rows}) == 100
        assert {next(iter(row['topics'])) for row in rows[:20]} == set(TOPICS)
        assert all(sum(topic in row['topics'] for row in rows) == 5 for topic in TOPICS)
    card = db.get(Article, 'curated-pompeii')
    card.summary = 'Previously imported introduction'
    db.commit()
    seed_catalog(db)
    assert card.summary == 'Previously imported introduction'
    assert db.scalar(select(func.count()).select_from(Article)) == 116


def test_three_months_of_recommendations_without_repeats(db):
    seed_catalog(db)
    user = User(email='catalog@example.com', password_hash='test', onboarded=True, interests=['music'])
    db.add(user)
    db.commit()
    start = datetime(2026, 1, 1, 12, tzinfo=timezone.utc)
    cards = [get_today(db, user, start + timedelta(days=i)).article_id for i in range(90)]
    assert len(set(cards)) == 90


def test_import_redirect_preserves_id_feedback_and_reimport(db):
    seed_catalog(db)
    user = User(email='import@example.com', password_hash='test')
    db.add(user)
    db.flush()
    db.add(Interaction(user_id=user.id, article_id='curated-pompeii', saved=True))
    db.commit()

    class Wiki:
        def articles(self, titles):
            return {'query': {'normalized': [{'from': titles[0], 'to': 'Normalized'}],
                'redirects': [{'from': 'Normalized', 'to': 'Canonical'}],
                'pages': [dict(title='Canonical', pageid=42, ns=0, extract='Real introduction',
                    fullurl='https://ru.wikipedia.org/wiki/Canonical')]}}

    assert import_curated(db, Wiki(), limit=1)['updated'] == 1
    assert import_curated(db, Wiki(), limit=1)['updated'] == 1
    seed_catalog(db)
    assert db.scalar(select(func.count()).select_from(Article)) == 116
    card = db.get(Article, 'curated-pompeii')
    assert (card.title, card.wikipedia_page_id, card.summary) == ('Canonical', 42, 'Real introduction')
    assert card.attribution['license'].endswith('/by-sa/4.0/')
    assert db.get(Interaction, (user.id, card.id)).saved


def test_import_skips_missing_disambiguation_empty_and_nonarticle(db):
    class Wiki:
        def articles(self, titles):
            data = response(titles)
            pages = data['query']['pages']
            pages[0]['missing'] = True
            pages[1]['pageprops'] = {'disambiguation': ''}
            pages[2]['extract'] = '  '
            pages[3]['ns'] = 14
            return data

    result = import_curated(db, Wiki(), 'en', 4)
    assert len(result['skipped']) == 4
    assert result['created'] == result['updated'] == 0


def test_english_import_uses_batches_and_is_recommendable(db):
    seed_catalog(db)

    class Wiki:
        calls = []

        def articles(self, titles):
            offset = len(self.calls) * 20
            self.calls.append(titles)
            data = response(titles)
            for page in data['query']['pages']:
                page['pageid'] += offset
            return data

    wiki = Wiki()
    assert import_curated(db, wiki, 'en', 21)['created'] == 21
    assert list(map(len, wiki.calls)) == [20, 1]
    user = User(email='english@example.com', password_hash='test', language='en', onboarded=True)
    db.add(user)
    db.commit()
    assert db.get(Article, get_today(db, user).article_id).language == 'en'


def test_budget_failure_preserves_previous_batch(db):
    class Wiki:
        calls = 0

        def articles(self, titles):
            self.calls += 1
            if self.calls == 2:
                raise RuntimeError('Wikimedia request budget exhausted')
            return response(titles)

    with pytest.raises(RuntimeError, match='budget exhausted'):
        import_curated(db, Wiki(), 'en', 21)
    assert db.scalar(select(func.count()).select_from(Article)) == 20
