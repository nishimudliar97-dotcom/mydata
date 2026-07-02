CREATE TABLE uploaded_documents (
    document_id SERIAL PRIMARY KEY,
    file_name TEXT NOT NULL,
    file_type TEXT,
    file_path TEXT,
    upload_status TEXT DEFAULT 'UPLOADED',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE extraction_jobs (
    job_id SERIAL PRIMARY KEY,
    document_id INT REFERENCES uploaded_documents(document_id),
    job_status TEXT DEFAULT 'PENDING',
    ocr_status TEXT DEFAULT 'PENDING',
    ai_extraction_status TEXT DEFAULT 'PENDING',
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE extracted_fields (
    field_id SERIAL PRIMARY KEY,
    job_id INT REFERENCES extraction_jobs(job_id),
    field_name TEXT NOT NULL,
    field_value TEXT,
    confidence_score NUMERIC(5,2),
    source_page INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE extraction_audit_logs (
    log_id SERIAL PRIMARY KEY,
    job_id INT REFERENCES extraction_jobs(job_id),
    step_name TEXT,
    status TEXT,
    message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
