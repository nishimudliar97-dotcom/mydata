from sqlalchemy import text
from Database.db_connection import create_mysql_engine


def load_cause_codes_from_db():
    """
    Reads cause codes from MySQL table: cause_code

    Expected columns:
    - cause_code_id
    - cause_l1
    - cause_l2
    """
    engine = create_mysql_engine()

    query = text("""
        SELECT
            cause_code_id,
            cause_l1,
            cause_l2
        FROM cause_code
        WHERE cause_code_id IS NOT NULL
    """)

    rows = []
    with engine.begin() as conn:
        result = conn.execute(query)
        for row in result.mappings():
            rows.append({
                "cause_code_id": row.get("cause_code_id"),
                "cause_l1": row.get("cause_l1"),
                "cause_l2": row.get("cause_l2")
            })

    return rows
