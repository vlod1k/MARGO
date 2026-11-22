"""Use the same eligibility and exclusion rules for stock and recommendations."""
from sqlalchemy import select, func, Boolean
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.sql.functions import FunctionElement
from .models import Article, DailyRecommendation, Interaction


class HasTopics(FunctionElement):
    type = Boolean()
    inherit_cache = True


@compiles(HasTopics, 'sqlite')
def sqlite_has_topics(element, compiler, **kwargs):
    column = compiler.process(element.clauses, **kwargs)
    return f"(json_type({column}) = 'object' AND EXISTS (SELECT 1 FROM json_each({column})))"


@compiles(HasTopics, 'postgresql')
def postgres_has_topics(element, compiler, **kwargs):
    column = compiler.process(element.clauses, **kwargs)
    return f"(jsonb_typeof(CAST({column} AS jsonb)) = 'object' AND CAST({column} AS jsonb) <> '{{}}'::jsonb)"


def eligible_articles():
    return select(Article).where(
        Article.available.is_(True), Article.classification_status == 'classified',
        HasTopics(Article.topics),
    )


def unseen_articles(user_id):
    assigned = select(DailyRecommendation.article_id).where(DailyRecommendation.user_id == user_id)
    consumed = select(Interaction.article_id).where(
        Interaction.user_id == user_id,
        (Interaction.read_at.is_not(None)) | (Interaction.feedback == 'known'),
    )
    return eligible_articles().where(Article.id.not_in(assigned), Article.id.not_in(consumed))


def inventory(db, user_id=None, low_watermark=30):
    result = {}
    for language in ('ru', 'en'):
        total = db.scalar(select(func.count()).select_from(
            eligible_articles().where(Article.language == language).subquery()))
        remaining = total if user_id is None else db.scalar(select(func.count()).select_from(
            unseen_articles(user_id).where(Article.language == language).subquery()))
        result[language] = {'available': total, 'remaining': remaining,
                            'low': remaining < low_watermark}
    return result
