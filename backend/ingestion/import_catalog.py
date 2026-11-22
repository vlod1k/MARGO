"""Run separately: python -m ingestion.import_catalog --source curated --limit 100 --budget 30."""
import argparse
from sqlalchemy import select
from app.article_identity import find_article
from app.database import SessionLocal
from app.models import Article, Subtopic, WikiCategory, CategoryMapping, CategoryEdge
from classification.engine import walk, classify, VERSION
from .mediawiki import MediaWiki
from .curated import import_curated

def run(limit,budget,language):
    wiki=MediaWiki(language,budget)
    try:
        with SessionLocal() as db:
            def store(page):
                row=db.scalar(select(WikiCategory).where(WikiCategory.language==language,WikiCategory.wiki_id==page['pageid']))
                if not row:
                    row=WikiCategory(wiki_id=page['pageid'],language=language,title=page['title']);db.add(row);db.flush()
                return row
            for subtopic in db.scalars(select(Subtopic)).all():
                for seed in subtopic.seed_categories:
                    title=seed if ':' in seed else ('Категория:' if language=='ru' else 'Category:')+seed
                    page=wiki.category(title)
                    if not page:
                        print('Skipped missing/non-category seed:',title);continue
                    def children(parent):
                        parent_page=wiki.category(parent)
                        if parent_page is None:return []
                        parent_row=store(parent_page);result=[]
                        for child in wiki.members(parent):
                            child_row=store(child)
                            if not db.get(CategoryEdge,(parent_row.id,child_row.id)):db.add(CategoryEdge(parent_id=parent_row.id,child_id=child_row.id))
                            result.append(child['title'])
                        return result
                    distances=walk(page['title'],children)
                    for category,distance in distances.items():
                        p=wiki.category(category)
                        if p:
                            row=store(p);key=(row.id,subtopic.slug,VERSION)
                            existing=db.get(CategoryMapping,key)
                            if existing: existing.distance=min(existing.distance,distance);existing.weight=.7**existing.distance
                            else:db.add(CategoryMapping(category_id=row.id,subtopic_id=subtopic.slug,version=VERSION,distance=distance,weight=.7**distance))
                    db.commit()
            mappings={}
            for mapping,category,subtopic in db.execute(select(CategoryMapping,WikiCategory,Subtopic).join(WikiCategory,CategoryMapping.category_id==WikiCategory.id).join(Subtopic,CategoryMapping.subtopic_id==Subtopic.slug).where(CategoryMapping.version==VERSION,WikiCategory.language==language)):
                mappings.setdefault(category.title,[]).append((subtopic.topic_id,mapping.distance))
            imported=0;visited=set()
            for title in mappings:
                for member in wiki.members(title,'page',limit=100):
                    id=f'{language}-{member["pageid"]}'
                    if id in visited:continue
                    visited.add(id)
                    if find_article(db,language,page_id=member['pageid']):continue
                    page=wiki.article(member['pageid'])
                    if page.get('missing') or not page.get('extract'):continue
                    existing=find_article(db,language,page_id=page['pageid'],article_id=id,
                        titles=(member['title'],page['title']),urls=(page['fullurl'],))
                    if existing is not None:
                        if existing.wikipedia_page_id is None:
                            existing.wikipedia_page_id=page['pageid'];db.commit()
                        continue
                    categories=[c['title'] for c in page.get('categories',[])]
                    weights=classify(categories,mappings) if page['categories_complete'] else {}
                    url=page['fullurl']
                    db.add(Article(id=f"{language}-{page['pageid']}",wikipedia_page_id=page['pageid'],language=language,title=page['title'],summary=page['extract'],url=url,topics=weights,categories=categories,classification_status='classified' if weights else 'unclassified',classification_version=VERSION,attribution={'source':url,'history':url+'?action=history','license':'https://creativecommons.org/licenses/by-sa/4.0/','notice':'Краткое описание из Википедии, CC BY-SA 4.0. Авторы — в истории изменений. Изображения не кэшируются.'}))
                    db.commit();imported+=1
                    if imported>=limit:return imported
            return imported
    finally:wiki.close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',choices=['curated','graph'],default='curated');p.add_argument('--limit',type=int);p.add_argument('--budget',type=int,default=1500);p.add_argument('--language',choices=['ru','en'],default='ru');args=p.parse_args()
    if args.limit is None:args.limit=100 if args.source=='curated' else 300
    if not 1<=args.limit<=5000 or not 1<=args.budget<=10000:p.error('limit 1..5000; budget 1..10000')
    if args.source=='curated':
        if args.limit>100:p.error('curated limit 1..100 per language')
        wiki=MediaWiki(args.language,args.budget)
        try:
            with SessionLocal() as db:print('Imported:',import_curated(db,wiki,args.language,args.limit))
        finally:wiki.close()
    else:print('Imported:',run(args.limit,args.budget,args.language))
