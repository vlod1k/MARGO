from contextlib import nullcontext
from urllib.parse import quote

import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session

from app.article_identity import find_article
from app.catalog import seed_catalog
from app.database import Base
from app.models import Article, Interaction, Subtopic, Topic, User
from ingestion.curated import import_curated
from ingestion import import_catalog
from ingestion.replenish import expand


@pytest.fixture
def db():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session
    engine.dispose()


class Wiki:
    closed = False

    def category(self, title):
        return {'title': title, 'pageid': 1000, 'ns': 14}

    def members(self, title, kind='subcat', limit=81):
        return list(self.iter_pages(title)) if kind == 'page' else []

    def iter_pages(self, title):
        yield {'pageid': 42, 'title': 'Исходное название'}
        yield {'pageid': 43, 'title': 'New page'}

    def article(self, page_id):
        return dict(pageid=page_id, title='Каноническое название' if page_id == 42 else 'New page',
                    ns=0, extract='Wikipedia introduction. ' * 10,
                    fullurl='https://ru.wikipedia.org/wiki/' + ('Каноническое_название' if page_id == 42 else 'New_page'),
                    categories=[], categories_complete=True)

    def articles(self, titles):
        return {'query': {'redirects': [{'from': titles[0], 'to': self.article(42)['title']}],
                          'pages': [self.article(43 if titles == ['New page'] else 42)]}}

    def close(self):
        self.closed = True


@pytest.mark.parametrize('importer', ['graph', 'curated', 'expand'])
@pytest.mark.parametrize('identity', ['page_id', 'title', 'url'])
def test_importers_reuse_editorial_identity(db, monkeypatch, importer, identity):
    wiki = Wiki()
    page = wiki.article(42)
    card = Article(id='editorial-card', language='ru',
                   wikipedia_page_id=42 if identity == 'page_id' else None,
                   title=page['title'] if identity == 'title' else 'Editorial title',
                   url=quote(page['fullurl'], safe=':/') if identity == 'url' else 'https://example.com/editorial',
                   summary='Editorial summary', topics={'history': 1}, available=False)
    user = User(email='identity@example.com', password_hash='test')
    db.add_all([card, user])
    db.flush()
    db.add(Interaction(user_id=user.id, article_id=card.id, saved=True))
    db.commit()

    if importer == 'curated':
        result = import_curated(db, wiki, limit=1)
        assert result['updated'] == 1 and result['created'] == 0
        assert import_curated(db, wiki, limit=1)['created'] == 0
    elif importer == 'expand':
        assert expand(db, wiki, 'ru', limit=1)['created'] == 1
        assert expand(db, wiki, 'ru', limit=1)['created'] == 0
    else:
        db.add(Topic(slug='history', name='History'))
        db.flush()
        db.add(Subtopic(slug='history-general', topic_id='history', name='History',
                        seed_categories=['Test']))
        db.commit()
        monkeypatch.setattr(import_catalog, 'SessionLocal', lambda: nullcontext(db))
        monkeypatch.setattr(import_catalog, 'MediaWiki', lambda *args: wiki)
        assert import_catalog.run(1, 100, 'ru') == 1
        assert import_catalog.run(1, 100, 'ru') == 0
        assert wiki.closed

    assert card.wikipedia_page_id == 42
    assert not card.available
    assert db.get(Interaction, (user.id, card.id)).saved
    assert db.get(Article, 'ru-42') is None
    assert db.scalar(select(func.count()).select_from(Article).where(Article.wikipedia_page_id == 42)) == 1
    if importer != 'curated':
        assert card.summary == 'Editorial summary'
        assert db.get(Article, 'ru-43') is not None


def test_identity_prioritizes_page_id_and_scopes_language(db):
    db.add_all([
        Article(id='canonical', language='ru', wikipedia_page_id=42, title='Moved', summary='', url='old'),
        Article(id='seed', language='ru', title='Target', summary='', url='target'),
        Article(id='english', language='en', wikipedia_page_id=42, title='Target', summary='', url='target'),
    ])
    db.commit()
    assert find_article(db, 'ru', page_id=42, article_id='seed', titles=('Target',), urls=('target',)).id == 'canonical'
    assert find_article(db, 'en', page_id=42).id == 'english'
    assert find_article(db, 'ru', page_id=43, titles=('Moved',), urls=('old',)) is None


@pytest.mark.parametrize('seed_id', ['antikythera', 'curated-pompeii'])
def test_seed_catalog_does_not_recreate_imported_card_under_another_id(db, seed_id):
    seed_catalog(db)
    card = db.get(Article, seed_id)
    card.id = 'ru-42'
    card.wikipedia_page_id = 42
    card.attribution = {}
    db.commit()
    seed_catalog(db)
    assert db.get(Article, seed_id) is None
    assert db.scalar(select(func.count()).select_from(Article)) == 116
