"""Import editorial targets without an expensive category-graph traversal."""
from itertools import islice
from app.article_identity import find_article
from app.curated import entries
from app.models import Article


def import_curated(db, wiki, language='ru', limit=100):
    if not 1 <= limit <= 100:
        raise ValueError('Curated limit must be 1..100 per language')
    targets = list(islice(entries(language), limit))
    result = {'created': 0, 'updated': 0, 'skipped': []}
    for offset in range(0, len(targets), 20):
        batch = targets[offset:offset + 20]
        data = wiki.articles([entry['title'] for entry in batch])
        query = data.get('query', {})
        aliases = {item['from']: item['to'] for key in ('normalized', 'converted', 'redirects') for item in query.get(key, [])}
        pages = {page['title']: page for page in query.get('pages', [])}
        for entry in batch:
            title = entry['title']
            visited = set()
            while title in aliases and title not in visited:
                visited.add(title)
                title = aliases[title]
            page = pages.get(title)
            if (not page or 'missing' in page or page.get('ns') != 0
                    or 'disambiguation' in page.get('pageprops', {})
                    or not page.get('extract', '').strip() or not page.get('pageid')):
                result['skipped'].append(entry['title'])
                continue
            url = page['fullurl']
            # Prefer the real page identity. Existing card IDs and interactions stay intact.
            article = find_article(db, language, page_id=page['pageid'], article_id=entry['id'],
                                   titles=(entry['title'], page['title']), urls=(url,))
            if article is None:
                article = Article(id=entry['id'], language=language)
                db.add(article)
                result['created'] += 1
            else:
                result['updated'] += 1
            article.wikipedia_page_id = page['pageid']
            article.title = page['title']
            article.summary = page['extract'].strip()
            article.url = url
            article.topics = {**(article.topics or {}), **entry['topics']}
            article.minutes = entry['minutes']
            article.classification_status = 'classified'
            article.classification_version = 'curated-v1'
            article.attribution = {
                'catalog_id': entry['id'],
                'source': url, 'history': url + '?action=history',
                'license': 'https://creativecommons.org/licenses/by-sa/4.0/',
                'notice': 'Краткое описание из Википедии, CC BY-SA 4.0. Авторы — в истории изменений. Тематика подобрана редакционно.',
            }
            # A failed later request does not discard already imported cards.
            db.commit()
    return result
