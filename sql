SELECT DISTINCT 
       MSG.T_SYSTEM_ID,
       TO_DATE(SUBSTR(MSG.T_FILTERED, 0, 10), 'YYYY/MM/DD') AS DATES,
       MSG.T_COPY_SERVICE,
       MSG.T_MESSAGE,
       MSG.T_FROMAPPLI,
       MSG.T_SENDER,
       MSG.T_RECEIVER,
       'CHATS' AS FLAG,

       -- Extract the ABIZSEV value into a column
       REGEXP_SUBSTR(
           MSG.T_MESSAGE,
           '\[ABIZSEV[^\]]*\]\s*([^\[]+)',
           1, 1, NULL, 1
       ) AS ABIZSEV_VALUE

FROM SANCTIONS_OWNER.FOFA_HIST_MESSAGE MSG

WHERE
(
      (MSG.T_FILTERED >= '2025/10/27 00:00:00' AND MSG.T_FILTERED <= '2025/10/27 23:59:59')
   OR (MSG.T_FILTERED >= '2025/11/03 00:00:00' AND MSG.T_FILTERED <= '2025/11/03 23:59:59')
   OR (MSG.T_FILTERED >= '2025/11/10 00:00:00' AND MSG.T_FILTERED <= '2025/11/10 23:59:59')
   OR (MSG.T_FILTERED >= '2025/11/17 00:00:00' AND MSG.T_FILTERED <= '2025/11/17 23:59:59')
   OR (MSG.T_FILTERED >= '2025/11/24 00:00:00' AND MSG.T_FILTERED <= '2025/11/24 23:59:59')
   OR (MSG.T_FILTERED >= '2025/12/01 00:00:00' AND MSG.T_FILTERED <= '2025/12/01 23:59:59')
)

-- 1️⃣ Ensure ABIZSEV tag exists
AND REGEXP_LIKE(MSG.T_MESSAGE, '\[ABIZSEV[^\]]*\]')

-- 2️⃣ Ensure ABIZSEV2 does NOT match by mistake
AND NOT REGEXP_LIKE(MSG.T_MESSAGE, '\[ABIZSEV2\]')

-- 3️⃣ Extract ABIZSEV value & check if it contains 'hkicl'
AND LOWER(
        REGEXP_SUBSTR(
            MSG.T_MESSAGE,
            '\[ABIZSEV[^\]]*\]\s*([^\[]+)',
            1, 1, NULL, 1
        )
    ) LIKE '%hkicl%'

-- 4️⃣ Your existing sender/receiver rule
AND (MSG.T_SENDER LIKE 'BARCHKHH%' OR MSG.T_RECEIVER LIKE 'BARCHKHH%')

-- 5️⃣ Existing operator
AND MSG.T_LASTOPERATOR = 'ReapplyEngine';
