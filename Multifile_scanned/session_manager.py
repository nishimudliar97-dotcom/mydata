from snowflake.snowpark import Session
from .config import AppConfig

def create_session(config: AppConfig) -> Session:
    return Session.builder.configs({
        "account": config.account,
        "user": config.user,
        "password": config.password,
        "role": config.role,
        "warehouse": config.warehouse,
        "database": config.database,
        "schema": config.schema,
    }).create()
