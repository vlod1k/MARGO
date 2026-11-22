import hashlib
import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from fastapi import HTTPException
from sqlalchemy import select
from .models import Article, DailyRecommendation, Interaction, SyncOperation, User
from .catalog import TOPICS
from recommendation import engine
from .inventory import inventory, unseen_articles

def article_json(article):
    data = {key:getattr(article,key) for key in ['id','title','summary','url','image_url','language','topics','minutes','attribution']}
    # Existing catalogs retain their article IDs and data after the rebrand.
    attribution = dict(data['attribution'] or {})
    if isinstance(attribution.get('notice'), str):
        attribution['notice'] = attribution['notice'].replace('THOTH', 'MARGO')
    data['attribution'] = attribution
    return data

def interaction_json(item):
    return {'article_id':item.article_id,'feedback':item.feedback,'saved':item.saved,'read_at':item.read_at,'version':item.version,'field_versions':item.field_versions}

def profile_json(db,user):
    interactions=db.scalars(select(Interaction).where(Interaction.user_id==user.id)).all()
    articles={a.id:a for a in db.scalars(select(Article)).all()}
    return {'id':user.id,'email':user.email,'name':user.name,'interests':user.interests,'weights':engine.interest_weights(user.interests,interactions,articles,TOPICS),'language':user.language,'timezone':user.timezone,'reminder':user.reminder,'notifications':user.notifications,'onboarded':user.onboarded,'version':user.preferences_version}

def get_today(db,user,instant=None):
    if not user.onboarded: raise HTTPException(409,'Сначала сохраните интересы и настройки профиля')
    local_date=(instant or datetime.now(timezone.utc)).astimezone(ZoneInfo(user.timezone)).date().isoformat()
    # Serializes assignment and feedback against this user's row in PostgreSQL.
    db.execute(select(User).where(User.id==user.id).with_for_update()).scalar_one()
    existing=db.scalar(select(DailyRecommendation).where(DailyRecommendation.user_id==user.id,DailyRecommendation.recommendation_date==local_date))
    if existing: return existing
    history=db.scalars(select(DailyRecommendation).where(DailyRecommendation.user_id==user.id).order_by(DailyRecommendation.recommendation_date)).all()
    interactions=db.scalars(select(Interaction).where(Interaction.user_id==user.id)).all()
    all_articles={a.id:a for a in db.scalars(select(Article)).all()}
    # "difficult" does not lower thematic interest; prefer shorter future cards.
    difficult={i.article_id for i in interactions if i.feedback=='difficult'}
    candidates=db.scalars(unseen_articles(user.id).where(Article.language==user.language)).all()
    weights=engine.interest_weights(user.interests,interactions,all_articles,TOPICS)
    recent=[t for d in history[-4:] for t in all_articles[d.article_id].topics]
    seen=[t for d in history for t in all_articles[d.article_id].topics]
    discovery=len(history)%5==4
    ranked=engine.rank(candidates,weights,recent,seen,discovery)
    if difficult: ranked=sorted(((score-.08*min(a.minutes/30,1),a) for score,a in ranked),key=lambda pair:(-pair[0],pair[1].id))
    if not ranked:
        stock=inventory(db,user.id)
        raise HTTPException(404,{'code':'catalog_exhausted' if stock[user.language]['available'] else 'catalog_empty',
                                'language':user.language,'inventory':stock})
    score,article=ranked[0]
    matched=[t for t in article.topics if t in user.interests]
    explanation='Новая тема для расширения кругозора' if discovery or not matched else f'Связана с вашим интересом к теме «{TOPICS[matched[0]]}»'
    item=DailyRecommendation(user_id=user.id,article_id=article.id,recommendation_date=local_date,score=score,mode='discovery' if discovery else 'personal',explanation=explanation)
    db.add(item);db.flush()
    return item

def recommendation_json(db,item):
    return {'date':item.recommendation_date,'mode':item.mode,'explanation':item.explanation,'article':article_json(db.get(Article,item.article_id))}

def apply_operation(db,user,op):
    # Keep fingerprints of operations from older clients unchanged.
    payload=op.model_dump(mode='json',exclude={'read_at'} if op.read_at is None else set())
    fingerprint=hashlib.sha256(json.dumps(payload,sort_keys=True).encode()).hexdigest()
    key=(user.id,str(op.operation_id))
    prior=db.get(SyncOperation,key)
    if prior:
        if prior.payload_hash!=fingerprint: raise HTTPException(409,'operation_id уже использован с другим содержимым')
        return prior.result
    if not db.get(Article,op.article_id): raise HTTPException(404,'Статья не найдена')
    if op.field=='saved' and type(op.value) is not bool: raise HTTPException(422,'saved требует bool')
    if op.field=='read' and type(op.value) is not bool: raise HTTPException(422,'read требует bool')
    if op.field=='feedback' and op.value not in [None,'liked','uninterested','known','difficult']: raise HTTPException(422,'Неизвестная оценка')
    item=db.get(Interaction,(user.id,op.article_id))
    if item is None:
        item=Interaction(user_id=user.id,article_id=op.article_id,field_versions={},version=0,saved=False)
        db.add(item);db.flush()
    versions=dict(item.field_versions)
    status='applied'
    # Server wins on a stale field. Independent fields never overwrite one another.
    if op.base_version!=versions.get(op.field,0): status='conflict'
    else:
        if op.field=='read':
            if not op.value: item.read_at=None
            elif not item.read_at: item.read_at=(op.read_at or datetime.now(timezone.utc)).astimezone(timezone.utc).isoformat()
        else: setattr(item,op.field,op.value)
        versions[op.field]=versions.get(op.field,0)+1
        item.field_versions=versions;item.version+=1
    result={'operation_id':str(op.operation_id),'status':status,'interaction':interaction_json(item)}
    db.add(SyncOperation(user_id=user.id,operation_id=str(op.operation_id),payload_hash=fingerprint,result=result))
    db.flush()
    return result

def sync_snapshot(db,user):
    history=db.scalars(select(DailyRecommendation).where(DailyRecommendation.user_id==user.id).order_by(DailyRecommendation.recommendation_date.desc())).all()
    interactions=db.scalars(select(Interaction).where(Interaction.user_id==user.id)).all()
    ids={d.article_id for d in history}|{i.article_id for i in interactions}
    return {'profile':profile_json(db,user),'catalog':inventory(db,user.id),'history':[recommendation_json(db,d) for d in history],'interactions':[interaction_json(i) for i in interactions],'articles':[article_json(db.get(Article,id)) for id in sorted(ids)]}
