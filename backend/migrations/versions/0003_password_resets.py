"""One-time password recovery codes (only hashes are stored)."""
import sqlalchemy as sa
from alembic import op

revision = '0003'
down_revision = '0002'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'password_resets',
        sa.Column('token_hash', sa.String(64), primary_key=True),
        sa.Column('user_id', sa.String(36), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False, unique=True),
        sa.Column('created_at', sa.String(40), nullable=False),
        sa.Column('expires_at', sa.String(40), nullable=False),
    )


def downgrade():
    op.drop_table('password_resets')
