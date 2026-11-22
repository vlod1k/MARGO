"""Persist the attempt budget for six-digit password reset codes."""
import sqlalchemy as sa
from alembic import op

revision = '0004'
down_revision = '0003'
branch_labels = None
depends_on = None


def upgrade():
    # Previously issued long codes are incompatible with the new confirmation API.
    op.execute(sa.text('DELETE FROM password_resets'))
    op.add_column('password_resets', sa.Column('attempts', sa.Integer(), nullable=False, server_default='0'))


def downgrade():
    op.drop_column('password_resets', 'attempts')
