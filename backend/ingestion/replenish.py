"""Bounded, repeatable expansion beyond the bundled editorial targets."""
import argparse
import json
import logging
import os
from datetime import datetime, timezone
from sqlalchemy import select
from app.article_identity import find_article
from app.database import SessionLocal
from app.inventory import inventory
from app.models import Article, User
from .curated import import_curated
from .mediawiki import MediaWiki

# Direct membership only. Category existence and namespace are checked at import.
# These are thematic rules, not a claim of human editorial review.
CATEGORIES = [
    ('history', 'Древний Рим', 'Ancient Rome'),
    ('physics', 'Оптика', 'Optics'),
    ('chemistry', 'Химические элементы', 'Chemical elements'),
    ('biology', 'Клеточная биология', 'Cell biology'),
    ('space', 'Планеты Солнечной системы', 'Planets of the Solar System'),
    ('technology', 'Изобретения', 'Inventions'),
    ('programming', 'Алгоритмы', 'Algorithms'),
    ('mathematics', 'Теория чисел', 'Number theory'),
    ('geography', 'Острова', 'Islands'),
    ('nature', 'Экосистемы', 'Ecosystems'),
    ('psychology', 'Когнитивная психология', 'Cognitive psychology'),
    ('philosophy', 'Философские понятия', 'Philosophical concepts'),
    ('art', 'Художественные направления', 'Art movements'),
    ('literature', 'Литературные жанры', 'Literary genres'),
    ('music', 'Музыкальные инструменты', 'Musical instruments'),
    ('languages', 'Письменности', 'Writing systems'),
    ('society', 'Права человека', 'Human rights'),
    ('economics', 'Микроэкономика', 'Microeconomics'),
    ('medicine', 'Иммунология', 'Immunology'),
    ('mythology', 'Египетская мифология', 'Egyptian mythology'),
]


def expand(db, wiki, language, limit=20, rotation=0):
    if language not in ('ru', 'en') or not 1 <= limit <= 200:
        raise ValueError('language ru/en; limit 1..200')
    result = {'created': 0, 'skipped': 0}
    offset = rotation % len(CATEGORIES)
    for topic, ru, en in CATEGORIES[offset:] + CATEGORIES[:offset]:
        title = ('Категория:' + ru) if language == 'ru' else ('Category:' + en)
        category = wiki.category(title)
        if not category:
            logging.warning('Missing replenishment category: %s/%s', language, title)
            continue
        # Per-topic quota spreads each run across subjects; rotate the first topic daily.
        added = 0
        for member in wiki.iter_pages(category['title']):
            if find_article(db, language, page_id=member['pageid']):
                continue
            data = wiki.articles([member['title']])
            pages = data.get('query', {}).get('pages', [])
            page = pages[0] if len(pages) == 1 else {}
            if (not page or 'missing' in page or page.get('ns') != 0
                    or 'disambiguation' in page.get('pageprops', {})
                    or len(page.get('extract', '').strip()) < 100 or not page.get('pageid')):
                result['skipped'] += 1
                continue
            # Redirects must not inherit membership of the redirect category.
            if page['pageid'] != member['pageid']:
                result['skipped'] += 1
                continue
            existing = find_article(db, language, page_id=page['pageid'],
                article_id=f"{language}-{page['pageid']}", titles=(member['title'], page['title']),
                urls=(page['fullurl'],))
            if existing:
                # Preserve editorial text, availability, IDs and interactions.
                if existing.wikipedia_page_id is None:
                    existing.wikipedia_page_id = page['pageid']
                    db.commit()
                continue
            url = page['fullurl']
            db.add(Article(id=f"{language}-{page['pageid']}", wikipedia_page_id=page['pageid'],
                language=language, title=page['title'], summary=page['extract'].strip(), url=url,
                topics={topic: 1.0}, categories=[category['title']], classification_status='classified',
                classification_version='category-direct-v1', attribution={
                    'source': url, 'history': url + '?action=history',
                    'license': 'https://creativecommons.org/licenses/by-sa/4.0/',
                    'notice': 'Краткое описание из Википедии, CC BY-SA 4.0. Авторы — в истории изменений. Тема определена по прямому вхождению в категорию.',
                }))
            db.commit()
            result['created'] += 1
            added += 1
            if result['created'] >= limit:
                return result
            if added >= max(1, (limit + len(CATEGORIES) - 1) // len(CATEGORIES)):
                break
    return result


def replenish(factory=SessionLocal, wiki_factory=MediaWiki):
    reports = {}
    watermark = int(os.getenv('MARGO_CATALOG_LOW_WATERMARK', '60'))
    limit = int(os.getenv('MARGO_CATALOG_BATCH', '20'))
    budget = int(os.getenv('MARGO_CATALOG_BUDGET', '100'))
    if not 1 <= watermark <= 5000 or not 1 <= limit <= 200 or not 1 <= budget <= 10000:
        raise ValueError('Invalid catalog watermark, batch or request budget')
    for language in ('ru', 'en'):
        wiki = None
        try:
            with factory() as db:
                stock = inventory(db)[language]['available']
                for user in db.scalars(select(User).where(User.onboarded.is_(True), User.language == language)):
                    stock = min(stock, inventory(db, user.id)[language]['remaining'])
                if stock >= watermark:
                    reports[language] = {'status': 'sufficient', 'minimum_remaining': stock}
                    continue
                wiki = wiki_factory(language, budget)
                # Bootstrap the English catalog and restore missing editorial targets.
                curated = import_curated(db, wiki, language)
                expanded = expand(db, wiki, language, limit, datetime.now(timezone.utc).date().toordinal())
                reports[language] = {'status': 'ok', 'curated': curated, 'expanded': expanded,
                                     'inventory': inventory(db)[language]}
                if expanded['created'] == 0:
                    logging.warning('Catalog %s did not grow beyond editorial targets', language)
        except Exception as exc:
            logging.exception('Catalog replenishment failed for %s', language)
            reports[language] = {'status': 'error', 'error': str(exc)}
        finally:
            if wiki is not None:
                wiki.close()
    logging.info('Catalog replenishment: %s', json.dumps(reports, ensure_ascii=False))
    return reports


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--status', action='store_true', help='Read stock without network requests')
    args = parser.parse_args()
    if args.status:
        with SessionLocal() as db:
            print(json.dumps(inventory(db), ensure_ascii=False, indent=2))
    else:
        report = replenish()
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if any(item['status'] == 'error' for item in report.values()):
            raise SystemExit(1)
