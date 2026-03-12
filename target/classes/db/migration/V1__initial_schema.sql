CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE tenant_status AS ENUM (
    'ACTIVE',
    'INACTIVE',
    'SUSPENDED'
);

CREATE TYPE certificate_status AS ENUM (
    'ACTIVE',
    'INACTIVE',
    'EXPIRED',
    'REVOKED'
);

CREATE TYPE document_type AS ENUM (
    'INVOICE',
    'RECEIPT',
    'CREDIT_NOTE',
    'DEBIT_NOTE'
);

CREATE TYPE document_status AS ENUM (
    'CREATED',
    'XML_GENERATED',
    'SIGNED',
    'QUEUED',
    'SENT',
    'ACCEPTED',
    'REJECTED',
    'ERROR',
    'RETRY_PENDING'
);

CREATE TYPE delivery_channel AS ENUM (
    'SUNAT',
    'OSE'
);

CREATE TYPE storage_file_type AS ENUM (
    'XML',
    'CDR',
    'PDF',
    'ATTACHMENT'
);

CREATE TYPE retry_result AS ENUM (
    'PENDING',
    'SUCCESS',
    'FAILED',
    'DEAD_LETTERED'
);

CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ruc VARCHAR(11) NOT NULL UNIQUE,
    legal_name TEXT NOT NULL,
    trade_name TEXT,
    fiscal_address TEXT,
    status tenant_status NOT NULL DEFAULT 'ACTIVE',
    encrypted_sunat_credentials JSONB,
    ose_configuration JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_tenants_ruc_format CHECK (ruc ~ '^[0-9]{11}$')
);

CREATE TABLE certificates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    alias TEXT NOT NULL,
    encrypted_certificate BYTEA NOT NULL,
    encrypted_password BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    status certificate_status NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_certificates_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants(id)
        ON DELETE RESTRICT
);

CREATE TABLE documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_type document_type NOT NULL,
    series VARCHAR(10) NOT NULL,
    sequence_number INTEGER NOT NULL,
    issue_date DATE NOT NULL,
    customer_document_type VARCHAR(10) NOT NULL,
    customer_document_number VARCHAR(20) NOT NULL,
    customer_name TEXT NOT NULL,
    currency CHAR(3) NOT NULL,
    subtotal NUMERIC(12, 2) NOT NULL,
    tax_amount NUMERIC(12, 2) NOT NULL,
    total NUMERIC(12, 2) NOT NULL,
    current_status document_status NOT NULL DEFAULT 'CREATED',
    delivery_channel delivery_channel NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_documents_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants(id)
        ON DELETE RESTRICT,
    CONSTRAINT uq_documents_tenant_fiscal_identity
        UNIQUE (tenant_id, document_type, series, sequence_number),
    CONSTRAINT uq_documents_id_tenant
        UNIQUE (id, tenant_id),
    CONSTRAINT chk_documents_sequence_number_positive
        CHECK (sequence_number > 0),
    CONSTRAINT chk_documents_currency_format
        CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT chk_documents_subtotal_nonnegative
        CHECK (subtotal >= 0),
    CONSTRAINT chk_documents_tax_amount_nonnegative
        CHECK (tax_amount >= 0),
    CONSTRAINT chk_documents_total_nonnegative
        CHECK (total >= 0),
    CONSTRAINT chk_documents_total_consistency
        CHECK (total = subtotal + tax_amount)
);

CREATE TABLE document_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_id UUID NOT NULL,
    description TEXT NOT NULL,
    quantity NUMERIC(12, 2) NOT NULL,
    unit_code VARCHAR(10),
    unit_value NUMERIC(12, 6) NOT NULL,
    unit_price NUMERIC(12, 6) NOT NULL,
    tax_amount NUMERIC(12, 2) NOT NULL,
    line_total NUMERIC(12, 2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_document_items_document
        FOREIGN KEY (document_id, tenant_id)
        REFERENCES documents(id, tenant_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_document_items_quantity_positive
        CHECK (quantity > 0),
    CONSTRAINT chk_document_items_unit_value_nonnegative
        CHECK (unit_value >= 0),
    CONSTRAINT chk_document_items_unit_price_nonnegative
        CHECK (unit_price >= 0),
    CONSTRAINT chk_document_items_tax_amount_nonnegative
        CHECK (tax_amount >= 0),
    CONSTRAINT chk_document_items_line_total_nonnegative
        CHECK (line_total >= 0)
);

CREATE TABLE document_status_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_id UUID NOT NULL,
    status document_status NOT NULL,
    transition_source VARCHAR(50) NOT NULL,
    details JSONB,
    event_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_document_status_history_document
        FOREIGN KEY (document_id, tenant_id)
        REFERENCES documents(id, tenant_id)
        ON DELETE CASCADE
);

CREATE TABLE document_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_id UUID NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    payload JSONB,
    correlation_id UUID,
    causation_id UUID,
    event_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_document_events_document
        FOREIGN KEY (document_id, tenant_id)
        REFERENCES documents(id, tenant_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_document_events_event_type
        CHECK (
            event_type IN (
                'invoice.created',
                'xml.generated',
                'xml.signed',
                'invoice.sent',
                'cdr.received',
                'pdf.generated',
                'invoice.retry'
            )
        )
);

CREATE TABLE delivery_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_id UUID NOT NULL,
    attempt_number INTEGER NOT NULL,
    reason VARCHAR(100),
    error_code VARCHAR(50),
    error_detail TEXT,
    next_retry_at TIMESTAMPTZ,
    executed_at TIMESTAMPTZ,
    result retry_result NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_delivery_attempts_document
        FOREIGN KEY (document_id, tenant_id)
        REFERENCES documents(id, tenant_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_delivery_attempts_document_attempt
        UNIQUE (document_id, attempt_number),
    CONSTRAINT chk_delivery_attempts_attempt_number_positive
        CHECK (attempt_number > 0)
);

CREATE TABLE storage_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    document_id UUID,
    file_type storage_file_type NOT NULL,
    storage_path TEXT NOT NULL,
    checksum VARCHAR(128),
    size_bytes BIGINT,
    mime_type VARCHAR(255),
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_storage_files_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_storage_files_document
        FOREIGN KEY (document_id, tenant_id)
        REFERENCES documents(id, tenant_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_storage_files_size_bytes_nonnegative
        CHECK (size_bytes IS NULL OR size_bytes >= 0),
    CONSTRAINT chk_storage_files_version_positive
        CHECK (version > 0)
);

CREATE UNIQUE INDEX uq_certificates_one_active_per_tenant
    ON certificates (tenant_id)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_certificates_tenant_status
    ON certificates (tenant_id, status);

CREATE INDEX idx_documents_tenant_status
    ON documents (tenant_id, current_status);

CREATE INDEX idx_documents_tenant_issue_date
    ON documents (tenant_id, issue_date DESC);

CREATE INDEX idx_documents_customer_document
    ON documents (tenant_id, customer_document_type, customer_document_number);

CREATE INDEX idx_document_items_document
    ON document_items (tenant_id, document_id);

CREATE INDEX idx_document_status_history_document_event_at
    ON document_status_history (tenant_id, document_id, event_at DESC);

CREATE INDEX idx_document_events_document_event_at
    ON document_events (tenant_id, document_id, event_at DESC);

CREATE INDEX idx_document_events_correlation_id
    ON document_events (correlation_id)
    WHERE correlation_id IS NOT NULL;

CREATE INDEX idx_delivery_attempts_next_retry_at
    ON delivery_attempts (next_retry_at)
    WHERE next_retry_at IS NOT NULL;

CREATE INDEX idx_delivery_attempts_document
    ON delivery_attempts (tenant_id, document_id, attempt_number DESC);

CREATE INDEX idx_storage_files_document_file_type
    ON storage_files (tenant_id, document_id, file_type);

CREATE UNIQUE INDEX uq_storage_files_path
    ON storage_files (storage_path);
