from types import SimpleNamespace as Obj
from datetime import datetime,timezone,timedelta
from uuid import uuid4
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from app.database import Base
from app.models import User, Article
from app.catalog import seed_catalog
from app.services import get_today
from classification.engine import walk,classify,evaluate
from recommendation.engine import rank

def test_graph_cycles_depth_service_and_max_weight():
    graph={'a':['b','Википедия:служебная'],'b':['a','c'],'c':['d']}
    assert walk('a',lambda t:graph[t])=={'a':0,'b':1,'c':2}
    assert classify(['a','b'],{'a':[('history',0)],'b':[('history',2),('technology',1)]})=={'history':1,'technology':.7}
    assert classify(['x'],{})=={}
    assert len(walk('a',lambda t:[str(i) for i in range(100)]))==1

def test_metrics():
    result=evaluate({'a':['history'],'b':['space']},{'a':['history'],'b':[]})
    assert result['unclassified_fraction']==.5
    assert result['topics']['history']['f1']==1

def test_discovery_prefers_unfamiliar_topics():
    known=Obj(id='a',topics={'history':1});new=Obj(id='b',topics={'space':1})
    assert rank([known,new],{'history':.8,'space':.2},[],[],False)[0][1].id=='a'
    assert rank([known,new],{'history':.8,'space':.2},[],[],True)[0][1].id=='b'

def test_daily_timezone_no_repeats_and_every_fifth_discovery(tmp_path):
    engine=create_engine('sqlite:///'+str(tmp_path/'daily.db'));Base.metadata.create_all(engine)
    with Session(engine) as db:
        seed_catalog(db);user=User(email='daily@example.com',password_hash='test',timezone='Europe/Moscow',interests=['history'],onboarded=True);db.add(user);db.commit()
        start=datetime(2026,11,4,22,tzinfo=timezone.utc)
        recommendations=[]
        for i in range(10):
            item=get_today(db,user,start+timedelta(days=i));db.commit();recommendations.append(item)
            assert item.article_id==get_today(db,user,start+timedelta(days=i)).article_id
        assert recommendations[0].recommendation_date=='2026-11-05'
        assert len({i.article_id for i in recommendations})==10
        assert [i.mode for i in recommendations].count('discovery')==2
    engine.dispose()
