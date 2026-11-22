"""Do not assign a first recommendation before choosing interests."""
import sqlalchemy as sa
from alembic import op
revision='0002'
down_revision='0001'
branch_labels=None
depends_on=None

def upgrade():
    op.add_column('users',sa.Column('onboarded',sa.Boolean(),nullable=False,server_default=sa.false()))
    # Existing accounts already used the previous preferences flow.
    op.execute(sa.text('UPDATE users SET onboarded = true WHERE preferences_version > 0'))

def downgrade():
    op.drop_column('users','onboarded')
