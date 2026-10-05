-- ==============================================================================
-- 00_schema_ddl.sql
-- FinOps & Strategic Consulting Practice - Analytical Lakehouse DDL & Partitioning Schema
--
-- Target: PostgreSQL 16 Enterprise / Amazon RDS Multi-AZ Aurora
-- Role: Data Scientist
-- Paradigm: DeliveryParadigm.C_LEVEL_EXECUTIVE_SUITE
-- Architecture: Time-Series Range Partitioning, BRIN Indexing & Audit Log
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS analytical_lakehouse;
SET search_path TO analytical_lakehouse, public;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ------------------------------------------------------------------------------
-- 1. Master Service Incident Telemetry Table (Range-Partitioned by Event Timestamp)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS service_incident_telemetry (
    telemetry_id UUID DEFAULT uuid_generate_v4(),
    incident_id VARCHAR(64) NOT NULL,
    service_cluster VARCHAR(64) NOT NULL,
    severity VARCHAR(32) NOT NULL,
    client_tier VARCHAR(64) NOT NULL,
    client_arr_usd NUMERIC(14, 2) NOT NULL,
    max_sla_hours NUMERIC(8, 2) NOT NULL,
    elapsed_hours NUMERIC(8, 2) NOT NULL,
    remaining_sla_hours NUMERIC(8, 2) NOT NULL,
    estimated_work_hours NUMERIC(8, 2) NOT NULL,
    hourly_penalty_usd NUMERIC(12, 2) NOT NULL,
    max_penalty_cap_usd NUMERIC(14, 2) NOT NULL,
    weibull_shape_k NUMERIC(6, 3) NOT NULL,
    weibull_scale_lambda NUMERIC(6, 3) NOT NULL,
    instantaneous_hazard_rate NUMERIC(10, 4) NOT NULL,
    conditional_breach_prob NUMERIC(6, 4) NOT NULL,
    expected_penalty_usd NUMERIC(14, 2) NOT NULL,
    recommended_specialty VARCHAR(64) NOT NULL,
    is_active_triage BOOLEAN NOT NULL DEFAULT TRUE,
    event_timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_service_incident_telemetry PRIMARY KEY (event_timestamp, telemetry_id)
) PARTITION BY RANGE (event_timestamp);

-- ------------------------------------------------------------------------------
-- 2. Time-Series Rolling Partitions (Quarterly Windows)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS service_incident_telemetry_2026_q1 PARTITION OF service_incident_telemetry
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS service_incident_telemetry_2026_q2 PARTITION OF service_incident_telemetry
    FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-07-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS service_incident_telemetry_2026_q3 PARTITION OF service_incident_telemetry
    FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS service_incident_telemetry_2026_q4 PARTITION OF service_incident_telemetry
    FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');

CREATE TABLE IF NOT EXISTS service_incident_telemetry_default PARTITION OF service_incident_telemetry
    DEFAULT;

-- ------------------------------------------------------------------------------
-- 3. High-Performance Indexing Strategy
-- ------------------------------------------------------------------------------
-- BRIN index on event timestamp: provides ~95% index space reduction over time series
CREATE INDEX IF NOT EXISTS idx_incident_telemetry_brin_timestamp 
    ON service_incident_telemetry USING BRIN (event_timestamp) 
    WITH (pages_per_range = 32);

-- B-Tree composite index for triage lookups by severity, cluster, and exposure
CREATE INDEX IF NOT EXISTS idx_incident_telemetry_triage 
    ON service_incident_telemetry (severity, service_cluster, expected_penalty_usd DESC);

-- Index on remaining SLA hours for urgent dispatch queues
CREATE INDEX IF NOT EXISTS idx_incident_telemetry_urgency 
    ON service_incident_telemetry (is_active_triage, remaining_sla_hours ASC);

-- ------------------------------------------------------------------------------
-- 4. Audit Table: SLA Breach & Hazard Anomaly Event Store
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sla_breach_anomaly_audit_log (
    audit_id BIGSERIAL PRIMARY KEY,
    incident_id VARCHAR(64) NOT NULL,
    service_cluster VARCHAR(64) NOT NULL,
    severity VARCHAR(32) NOT NULL,
    client_tier VARCHAR(64) NOT NULL,
    instantaneous_hazard_rate NUMERIC(10, 4) NOT NULL,
    conditional_breach_prob NUMERIC(6, 4) NOT NULL,
    expected_penalty_usd NUMERIC(14, 2) NOT NULL,
    anomaly_reason VARCHAR(255) NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);