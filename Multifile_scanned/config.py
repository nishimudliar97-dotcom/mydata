import os
from dataclasses import dataclass
from dotenv import load_dotenv

@dataclass
class AppConfig:
    account: str
    user: str
    password: str
    role: str
    warehouse: str
    database: str
    schema: str
    stage_name: str
    parse_mode: str
    page_split: bool

def load_config() -> AppConfig:
    load_dotenv()
    return AppConfig(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ.get("SNOWFLAKE_ROLE", "ACCOUNTADMIN"),
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
        schema=os.environ["SNOWFLAKE_SCHEMA"],
        stage_name=os.environ["STAGE_NAME"],
        parse_mode=os.environ.get("PARSE_MODE", "LAYOUT"),
        page_split=os.environ.get("PAGE_SPLIT", "true").lower() == "true",
    )
