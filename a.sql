SELECT 
    'SELECT COUNT(*) AS total_rows, ' ||
    LISTAGG(
        'COUNT(' || COLUMN_NAME || ') AS ' || COLUMN_NAME || '_filled, ' ||
        'COUNT(' || COLUMN_NAME || ') * 100.0 / COUNT(*) AS ' || COLUMN_NAME || '_fill_rate',
        ', '
    ) 
    || ' FROM du_prod.reporting_common.underwriting_risk
       WHERE inwardrisksection_targetmarket IN (''Prop Ins Intl D&F'', ''Prop Ins US D&F'')
       AND inwardsubmission_placingbasisname IN (''Insurance'', ''Fac RI'')
       AND YEAR(inwardrisksection_inceptiondate) = 2025'
AS query
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'UNDERWRITING_RISK'
  AND TABLE_SCHEMA = 'REPORTING_COMMON';




SELECT column_name,
       COUNT(*) AS total_rows,
       COUNT(value) AS filled_rows,
       COUNT(value) * 100.0 / COUNT(*) AS fill_rate
FROM du_prod.reporting_common.underwriting_risk
UNPIVOT(value FOR column_name IN (
    inwardlayerr_ntureason,
    inwardsubmission_placingbasisname
    -- add more columns
))
WHERE inwardrisksection_targetmarket IN ('Prop Ins Intl D&F', 'Prop Ins US D&F')
  AND inwardsubmission_placingbasisname IN ('Insurance', 'Fac RI')
  AND YEAR(inwardrisksection_inceptiondate) = 2025
GROUP BY column_name;
