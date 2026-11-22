from .database import SessionLocal
from .catalog import seed_catalog
if __name__=='__main__':
    with SessionLocal() as db: seed_catalog(db)
