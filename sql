AND
(
    REGEXP_LIKE(MSG.T_MESSAGE, '\[ABIZSEV[^\]]*\]')
    AND NOT REGEXP_LIKE(MSG.T_MESSAGE, '\[ABIZSEV2\]')

    AND LOWER(
        REGEXP_SUBSTR(
            MSG.T_MESSAGE,
            '\[ABIZSEV[^\]]*\]\s*([^\[]+)',
            1, 1, NULL, 1
        )
    ) LIKE '%hkicl%'
)
