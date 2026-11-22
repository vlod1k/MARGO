from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from pydantic import AwareDatetime, BaseModel, EmailStr, Field, field_validator, model_validator
from .catalog import TOPICS

Feedback = Literal['liked','uninterested','known','difficult']
class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8,max_length=128)
class Registration(Credentials):
    name: str = Field(default='Исследователь',min_length=1,max_length=80)
class PasswordResetRequest(BaseModel):
    email: EmailStr
class PasswordResetConfirm(BaseModel):
    email: EmailStr
    token: str = Field(min_length=6,max_length=6,pattern=r'^[0-9]{6}$')
    new_password: str = Field(min_length=8,max_length=128)
class PasswordChange(BaseModel):
    current_password: str = Field(min_length=8,max_length=128)
    new_password: str = Field(min_length=8,max_length=128)
class Preferences(BaseModel):
    name: str = Field(min_length=1,max_length=80)
    interests: list[str] = Field(max_length=20)
    language: Literal['ru','en'] = 'ru'
    timezone: str = 'Europe/Moscow'
    reminder: str = Field(default='09:00',pattern=r'^(?:[01]\d|2[0-3]):[0-5]\d$')
    notifications: bool = False
    version: int = Field(ge=0)
    @field_validator('interests')
    @classmethod
    def topics_exist(cls,value):
        if len(value)!=len(set(value)) or any(t not in TOPICS for t in value): raise ValueError('Неизвестные или повторяющиеся темы')
        return value
    @field_validator('timezone')
    @classmethod
    def zone_exists(cls,value):
        try: ZoneInfo(value)
        except (ZoneInfoNotFoundError,ValueError): raise ValueError('Неизвестный часовой пояс')
        return value
class Operation(BaseModel):
    operation_id: UUID
    article_id: str = Field(min_length=1,max_length=60)
    field: Literal['saved','feedback','read']
    value: bool | Feedback | None
    base_version: int = Field(ge=0)
    read_at: AwareDatetime | None = None

    @field_validator('read_at', mode='before')
    @classmethod
    def read_time_is_string(cls, value):
        if value is not None and not isinstance(value, str):
            raise ValueError('read_at требует строку ISO 8601 с часовым поясом')
        if value is not None:
            datetime.fromisoformat(value)
        return value

    @model_validator(mode='after')
    def validate_read_time(self):
        if self.read_at is not None:
            if self.field != 'read' or self.value is not True:
                raise ValueError('read_at допустимо только для read=true')
            if self.read_at > datetime.now(timezone.utc) + timedelta(minutes=5):
                raise ValueError('read_at не может быть в будущем (допуск 5 минут)')
        return self
class SyncRequest(BaseModel):
    operations: list[Operation] = Field(max_length=100)
class Vote(BaseModel):
    operation_id: UUID
    feedback: Feedback | None
    base_version: int = Field(ge=0)
class SaveRequest(BaseModel):
    operation_id: UUID
    base_version: int = Field(ge=0)
class DeviceRequest(BaseModel):
    platform: Literal['android','ios']
    token: str = Field(min_length=16,max_length=4096)
