from urllib.parse import quote
from sqlalchemy import select
from .article_identity import find_article
from .models import Article, Topic, Subtopic
from .curated import entries

TOPICS = dict(zip(
    ['history','physics','chemistry','biology','space','technology','programming','mathematics','geography','nature','psychology','philosophy','art','literature','music','languages','society','economics','medicine','mythology'],
    ['История','Физика','Химия','Биология','Космос','Технологии','Программирование','Математика','География','Природа и экология','Психология','Философия','Искусство','Литература','Музыка','Языки','Общество и право','Экономика','Медицина','Мифология и религии']))
# Original short descriptions, manually classified; never presented as measured classifier output.
SEEDS = [
 ('antikythera','Антикитерский механизм','Бронзовые шестерёнки, которые предсказывали движение небесных тел за две тысячи лет до появления компьютеров.',{'history':1,'technology':.9,'space':.7},12),
 ('aurora','Полярное сияние','Встреча солнечного ветра и магнитного поля Земли, превращающая ночное небо в полотно света.',{'physics':1,'nature':.8},8),
 ('bauhaus','Баухаус','Школа, объединившая искусство, архитектуру и ремесло в поиске новой повседневной эстетики.',{'art':1,'history':.6},10),
 ('mycelium','Мицелий','Невидимая грибная сеть под нашими ногами и её роль в жизни леса.',{'biology':1,'nature':1},7),
 ('voyager','Золотая пластинка «Вояджера»','Музыка, голоса и изображения Земли в послании для возможных внеземных цивилизаций.',{'space':1,'music':.6},9),
 ('fibonacci','Числа Фибоначчи','Последовательность чисел, связывающая математику с узорами живой природы.',{'mathematics':1,'nature':.5},11),
 ('stoicism','Стоицизм','Античная философия о свободе выбора, спокойствии и внимании к настоящему.',{'philosophy':1,'history':.6},14),
 ('rosetta','Розеттский камень','Одна надпись на трёх языках, открывшая путь к чтению древнеегипетской письменности.',{'languages':1,'history':.9},9),
 ('turing','Машина Тьюринга','Мысленный эксперимент, который помогает определить границы вычислимого.',{'programming':1,'mathematics':.8},13),
 ('periodic','Периодическая система химических элементов','Порядок в разнообразии вещества: как свойства элементов складываются в закономерность.',{'chemistry':1,'history':.3},10),
 ('memory','Память','Как мы сохраняем опыт, вспоминаем прошлое и почему воспоминания меняются.',{'psychology':1,'biology':.4},12),
 ('silkroad','Великий шёлковый путь','Маршруты, по которым между цивилизациями путешествовали товары, идеи и изобретения.',{'geography':1,'economics':.6,'history':.9},10),
 ('haiku','Хайку','Японская поэзия, которая учит замечать целый мир в одном кратком мгновении.',{'literature':1,'languages':.5},7),
 ('thoth','Тот','Бог мудрости, письменности и счёта в мифологии Древнего Египта.',{'mythology':1,'history':.7},8),
 ('vaccine','Вакцина','История и принципы подготовки иммунной системы к встрече с инфекцией.',{'medicine':1,'biology':.8},12),
 ('law','Всеобщая декларация прав человека','Документ, сформулировавший общий язык основных прав и свобод.',{'society':1,'history':.5},9),
]

def seed_catalog(db):
    for slug, name in TOPICS.items():
        if not db.get(Topic,slug): db.add(Topic(slug=slug,name=name))
    db.flush()
    for slug,name in TOPICS.items():
        if not db.get(Subtopic,slug+'-general'):
            db.add(Subtopic(slug=slug+'-general',topic_id=slug,name=name,seed_categories=[name]))
    for id,title,summary,weights,minutes in SEEDS:
        if not find_article(db,'ru',article_id=id,titles=(title,)):
            url='https://ru.wikipedia.org/wiki/'+quote(title.replace(' ','_'))
            db.add(Article(id=id,title=title,summary=summary,url=url,topics=weights,minutes=minutes,classification_status='classified',attribution={'source':url,'history':url+'?action=history','notice':'Авторское краткое описание MARGO. Полный текст и сведения об авторах — в Википедии.'}))
    imported_entries={a.attribution.get('catalog_id') for a in db.scalars(select(Article)).all() if a.attribution}
    for entry in entries():
        url='https://ru.wikipedia.org/wiki/'+quote(entry['title'].replace(' ','_'))
        existing=find_article(db,'ru',article_id=entry['id'],titles=(entry['title'],),urls=(url,))
        if not existing and entry['id'] not in imported_entries:
            db.add(Article(**entry,language='ru',url=url,classification_status='classified',classification_version='curated-v1',attribution={'source':url,'history':url+'?action=history','notice':'Авторское краткое описание MARGO. Тематика подобрана редакционно. Полный текст и сведения об авторах — в Википедии.'}))
    db.commit()
