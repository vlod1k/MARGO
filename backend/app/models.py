from datetime import datetime, timezone
from uuid import uuid4
from sqlalchemy import String, Text, ForeignKey, UniqueConstraint, Index, JSON
from sqlalchemy.orm import Mapped, mapped_column
from .database import Base

def uid(): return str(uuid4())
def now(): return datetime.now(timezone.utc).isoformat()

class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    email: Mapped[str] = mapped_column(String(254), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(Text)
    name: Mapped[str] = mapped_column(String(80), default="Исследователь")
    language: Mapped[str] = mapped_column(String(5), default="ru")
    timezone: Mapped[str] = mapped_column(String(80), default="Europe/Moscow")
    reminder: Mapped[str] = mapped_column(String(5), default="09:00")
    notifications: Mapped[bool] = mapped_column(default=False)
    onboarded: Mapped[bool] = mapped_column(default=False)
    interests: Mapped[list] = mapped_column(JSON, default=list)
    preferences_version: Mapped[int] = mapped_column(default=0)
    created_at: Mapped[str] = mapped_column(String(40), default=now)

class Session(Base):
    __tablename__ = "sessions"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    expires_at: Mapped[str] = mapped_column(String(40))

class PasswordReset(Base):
    __tablename__ = "password_resets"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True)
    created_at: Mapped[str] = mapped_column(String(40), default=now)
    expires_at: Mapped[str] = mapped_column(String(40))
    attempts: Mapped[int] = mapped_column(default=0, server_default='0')

class Topic(Base):
    __tablename__ = "topics"
    slug: Mapped[str] = mapped_column(String(60), primary_key=True)
    name: Mapped[str] = mapped_column(String(80))

class Subtopic(Base):
    __tablename__ = "subtopics"
    slug: Mapped[str] = mapped_column(String(80), primary_key=True)
    topic_id: Mapped[str] = mapped_column(ForeignKey("topics.slug"))
    name: Mapped[str] = mapped_column(String(100))
    seed_categories: Mapped[list] = mapped_column(JSON, default=list)

class WikiCategory(Base):
    __tablename__ = "wiki_categories"
    id: Mapped[int] = mapped_column(primary_key=True)
    wiki_id: Mapped[int]
    language: Mapped[str] = mapped_column(String(5))
    title: Mapped[str] = mapped_column(String(512))
    __table_args__ = (UniqueConstraint("language", "wiki_id"),)

class CategoryEdge(Base):
    __tablename__ = "category_edges"
    parent_id: Mapped[int] = mapped_column(ForeignKey("wiki_categories.id", ondelete="CASCADE"), primary_key=True)
    child_id: Mapped[int] = mapped_column(ForeignKey("wiki_categories.id", ondelete="CASCADE"), primary_key=True)

class CategoryMapping(Base):
    __tablename__ = "category_mappings"
    category_id: Mapped[int] = mapped_column(ForeignKey("wiki_categories.id", ondelete="CASCADE"), primary_key=True)
    subtopic_id: Mapped[str] = mapped_column(ForeignKey("subtopics.slug"), primary_key=True)
    version: Mapped[str] = mapped_column(String(40), primary_key=True)
    distance: Mapped[int]
    weight: Mapped[float]

class Article(Base):
    __tablename__ = "articles"
    id: Mapped[str] = mapped_column(String(60), primary_key=True)
    wikipedia_page_id: Mapped[int | None]
    language: Mapped[str] = mapped_column(String(5), default="ru")
    title: Mapped[str] = mapped_column(String(512))
    summary: Mapped[str] = mapped_column(Text)
    url: Mapped[str] = mapped_column(Text)
    image_url: Mapped[str | None] = mapped_column(Text)
    topics: Mapped[dict] = mapped_column(JSON, default=dict)
    categories: Mapped[list] = mapped_column(JSON, default=list)
    classification_status: Mapped[str] = mapped_column(String(30), default="unclassified")
    classification_version: Mapped[str] = mapped_column(String(40), default="seed-v1")
    available: Mapped[bool] = mapped_column(default=True)
    minutes: Mapped[int] = mapped_column(default=8)
    attribution: Mapped[dict] = mapped_column(JSON, default=dict)
    __table_args__ = (UniqueConstraint("language", "wikipedia_page_id"),)

class Interaction(Base):
    __tablename__ = "interactions"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id"), primary_key=True)
    feedback: Mapped[str | None] = mapped_column(String(20))
    saved: Mapped[bool] = mapped_column(default=False)
    read_at: Mapped[str | None] = mapped_column(String(40))
    version: Mapped[int] = mapped_column(default=0)
    # Each field has its own version: an offline save must not erase a newer vote.
    field_versions: Mapped[dict] = mapped_column(JSON, default=dict)

class DailyRecommendation(Base):
    __tablename__ = "daily_recommendations"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id"))
    recommendation_date: Mapped[str] = mapped_column(String(10))
    score: Mapped[float]
    mode: Mapped[str] = mapped_column(String(20))
    explanation: Mapped[str] = mapped_column(Text)
    notification_sent_at: Mapped[str | None] = mapped_column(String(40))
    __table_args__ = (UniqueConstraint("user_id", "recommendation_date"), UniqueConstraint("user_id", "article_id"), Index("ix_daily_user_date", "user_id", "recommendation_date"))

class SyncOperation(Base):
    __tablename__ = "sync_operations"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    operation_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    payload_hash: Mapped[str] = mapped_column(String(64))
    result: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[str] = mapped_column(String(40), default=now)

class DeviceToken(Base):
    __tablename__ = "device_tokens"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    platform: Mapped[str] = mapped_column(String(20))
    token: Mapped[str] = mapped_column(Text)
    __table_args__ = (UniqueConstraint("user_id", "token"),)
