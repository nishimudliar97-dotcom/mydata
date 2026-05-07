LIST @OPEN_MARKET_QUOTE/Open_Market
PATTERN = '.*[.](pdf|png|jpg|jpeg|doc|docx)$';

SELECT
    REGEXP_SUBSTR("name", 'Open_Market/([^/]+)/', 1, 1, 'e', 1) AS account_folder,
    COUNT(*) AS file_count,
    LISTAGG(SPLIT_PART("name", '/', -1), ', ') AS file_names
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE REGEXP_SUBSTR("name", 'Open_Market/([^/]+)/', 1, 1, 'e', 1) IS NOT NULL
GROUP BY account_folder
ORDER BY file_count DESC;
