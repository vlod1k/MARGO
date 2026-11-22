"""Shared article identity lookup for bundled and Wikipedia importers."""
from urllib.parse import quote, unquote

from sqlalchemy import or_, select

from .models import Article


def find_article(db, language, *, page_id=None, article_id=None, titles=(), urls=()):
    """Prefer Wikipedia identity; use local identity for unresolved seed cards.

    A known, different page ID must never be matched just by title or URL.
    The caller owns updates so editorial content and interactions stay intact.
    """
    query = select(Article).where(Article.language == language)
    if page_id is not None:
        article = db.scalar(query.where(Article.wikipedia_page_id == page_id))
        if article is not None:
            return article
        query = query.where(Article.wikipedia_page_id.is_(None))
    if article_id is not None:
        article = db.scalar(query.where(Article.id == article_id))
        if article is not None:
            return article
    title_variants = {title.replace('_', ' ') for title in titles if title}
    url_variants = set()
    for url in urls:
        if url:
            url_variants.update((url, unquote(url)))
    for title in title_variants:
        url = f'https://{language}.wikipedia.org/wiki/' + title.replace(' ', '_')
        url_variants.update((url, quote(url, safe=':/')))
    matches = []
    if title_variants:
        matches.append(Article.title.in_(title_variants | {t.replace(' ', '_') for t in title_variants}))
    if url_variants:
        matches.append(Article.url.in_(url_variants))
    return db.scalar(query.where(or_(*matches)).order_by(Article.id)) if matches else None
