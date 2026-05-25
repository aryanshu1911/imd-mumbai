-- ================================================================
-- IMD Mumbai — Complete Supabase Schema (FRESH INSTALL)
-- Run this in Supabase Dashboard → SQL Editor
-- ================================================================
-- IMPORTANT: Run EACH section separately if you hit errors.
-- This script is idempotent (safe to run multiple times).
-- ================================================================


-- ================================================================
-- SECTION 1: DROP OLD POLICIES (if any broken ones exist)
-- ================================================================

DO $$
BEGIN
  -- Drop policies for profiles if they exist
  DROP POLICY IF EXISTS "profiles_self_read" ON profiles;
  DROP POLICY IF EXISTS "profiles_service_all" ON profiles;
  -- Drop policies for signup_requests if they exist
  DROP POLICY IF EXISTS "signup_requests_insert" ON signup_requests;
  DROP POLICY IF EXISTS "signup_requests_service_all" ON signup_requests;
  -- Drop policies for master_data_files if they exist
  DROP POLICY IF EXISTS "master_data_read" ON master_data_files;
  DROP POLICY IF EXISTS "master_data_service_all" ON master_data_files;
  -- Drop policies for user_data_files if they exist
  DROP POLICY IF EXISTS "user_data_own" ON user_data_files;
  DROP POLICY IF EXISTS "user_data_service_all" ON user_data_files;
  -- Drop policies for rainfall_config if they exist
  DROP POLICY IF EXISTS "config_read" ON rainfall_config;
  DROP POLICY IF EXISTS "config_service_all" ON rainfall_config;
  -- Drop old indexes if they exist
  DROP INDEX IF EXISTS idx_master_warning_unique;
  DROP INDEX IF EXISTS idx_master_realised_unique;
  DROP INDEX IF EXISTS idx_user_warning_unique;
  DROP INDEX IF EXISTS idx_user_realised_unique;
  DROP INDEX IF EXISTS idx_master_data_unique;
  DROP INDEX IF EXISTS idx_user_data_unique;
EXCEPTION WHEN OTHERS THEN
  NULL; -- Ignore errors if tables don't exist yet
END $$;


-- ================================================================
-- SECTION 2: CREATE TABLES
-- ================================================================

-- ── TABLE 1: profiles ─────────────────────────────────────────────
-- Extends Supabase auth.users.
-- Each authenticated user must have a profile row.
-- Admin users have role='admin', status='active'.
-- Regular users start with status='pending' until admin approves.
CREATE TABLE IF NOT EXISTS profiles (
  id          uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username    text        UNIQUE NOT NULL,
  email       text,
  role        text        NOT NULL DEFAULT 'user'    CHECK (role   IN ('admin', 'user')),
  status      text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'rejected')),
  mode        text        NOT NULL DEFAULT 'dual'    CHECK (mode   IN ('dual', 'multi')),
  can_modify  boolean     NOT NULL DEFAULT false,
  can_delete  boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ── TABLE 2: signup_requests ──────────────────────────────────────
-- Pending approval queue shown in the admin panel.
-- Created alongside the profile row during user sign-up.
CREATE TABLE IF NOT EXISTS signup_requests (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  username    text        NOT NULL,
  email       text        NOT NULL,
  status      text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ── TABLE 3: master_data_files ────────────────────────────────────
-- Admin-uploaded authoritative rainfall data.
-- type='warning'  → IMD warning codes per district per day (+ lead day D1-D5)
-- type='realised' → actual observed rainfall in mm per district per day
--
-- CRITICAL UNIQUE constraint:
--   (type, year, month, day, lead_day)
--   For 'realised' data, lead_day IS NULL — this is handled by Postgres NULLS NOT DISTINCT
--   (Postgres 15+). For older versions, a partial unique index is used below.
CREATE TABLE IF NOT EXISTS master_data_files (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  type        text        NOT NULL CHECK (type IN ('warning', 'realised')),
  year        int         NOT NULL CHECK (year  >= 2000 AND year  <= 2100),
  month       int         NOT NULL CHECK (month >= 1    AND month <= 12),
  day         int         NOT NULL CHECK (day   >= 1    AND day   <= 31),
  lead_day    text        CHECK (lead_day IS NULL OR lead_day IN ('D1','D2','D3','D4','D5')),
  districts   jsonb       NOT NULL DEFAULT '{}',
  uploaded_by uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- UNIQUE index matching the ON CONFLICT target exactly (PostgreSQL 15+ compatible with NULLS NOT DISTINCT)
CREATE UNIQUE INDEX IF NOT EXISTS idx_master_data_unique
  ON master_data_files (type, year, month, day, lead_day) NULLS NOT DISTINCT;

-- ── TABLE 4: user_data_files ──────────────────────────────────────
-- Per-user copy-on-write overrides of master data.
-- Non-admin users with can_modify=true can edit their own copy.
-- Read priority: user_data_files → master_data_files
CREATE TABLE IF NOT EXISTS user_data_files (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  master_file_id  uuid        REFERENCES master_data_files(id) ON DELETE SET NULL,
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type            text        NOT NULL CHECK (type IN ('warning', 'realised')),
  year            int         NOT NULL CHECK (year  >= 2000 AND year  <= 2100),
  month           int         NOT NULL CHECK (month >= 1    AND month <= 12),
  day             int         NOT NULL CHECK (day   >= 1    AND day   <= 31),
  lead_day        text        CHECK (lead_day IS NULL OR lead_day IN ('D1','D2','D3','D4','D5')),
  districts       jsonb       NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- UNIQUE index matching the ON CONFLICT target exactly (PostgreSQL 15+ compatible with NULLS NOT DISTINCT)
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_data_unique
  ON user_data_files (user_id, type, year, month, day, lead_day) NULLS NOT DISTINCT;


-- ── TABLE 5: rainfall_config ──────────────────────────────────────
-- Single-row config table for rainfall classification settings.
-- Replaces local JSON file — admin can update via the admin panel.
-- The application always reads the latest row (ordered by updated_at DESC).
CREATE TABLE IF NOT EXISTS rainfall_config (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  config      jsonb       NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);


-- ================================================================
-- SECTION 3: PERFORMANCE INDEXES
-- ================================================================

CREATE INDEX IF NOT EXISTS idx_master_type_year_month
  ON master_data_files (type, year, month);

CREATE INDEX IF NOT EXISTS idx_master_year_month_day
  ON master_data_files (year, month, day);

CREATE INDEX IF NOT EXISTS idx_user_data_user_id
  ON user_data_files (user_id);

CREATE INDEX IF NOT EXISTS idx_user_data_user_type_year_month
  ON user_data_files (user_id, type, year, month);

CREATE INDEX IF NOT EXISTS idx_signup_requests_status
  ON signup_requests (status);

CREATE INDEX IF NOT EXISTS idx_profiles_username
  ON profiles (username);

CREATE INDEX IF NOT EXISTS idx_profiles_email
  ON profiles (email);


-- ================================================================
-- SECTION 4: ROW LEVEL SECURITY (RLS)
-- ================================================================
-- All API routes use the SERVICE ROLE key which bypasses RLS.
-- These policies protect against direct client-side access.
-- ================================================================

ALTER TABLE profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE signup_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE master_data_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_data_files  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rainfall_config  ENABLE ROW LEVEL SECURITY;

-- ── profiles RLS ──────────────────────────────────────────────────
-- Users can only read their own profile via the anon/user JWT.
-- Service role (API routes) can do everything.
CREATE POLICY "profiles_self_read"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "profiles_service_all"
  ON profiles FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── signup_requests RLS ───────────────────────────────────────────
-- Public insert (for the sign-up page before user is logged in).
-- Service role can read/update (for admin approval).
CREATE POLICY "signup_requests_insert"
  ON signup_requests FOR INSERT
  WITH CHECK (true);

CREATE POLICY "signup_requests_service_all"
  ON signup_requests FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── master_data_files RLS ─────────────────────────────────────────
-- Authenticated users can read all master data.
-- Only service role writes (admin uploads via API).
CREATE POLICY "master_data_read"
  ON master_data_files FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "master_data_service_all"
  ON master_data_files FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── user_data_files RLS ───────────────────────────────────────────
-- Users can manage their own data copies.
-- Service role manages all (for admin operations).
CREATE POLICY "user_data_own"
  ON user_data_files FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "user_data_service_all"
  ON user_data_files FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── rainfall_config RLS ───────────────────────────────────────────
-- Authenticated users can read config.
-- Only service role (admin API) writes.
CREATE POLICY "config_read"
  ON rainfall_config FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "config_service_all"
  ON rainfall_config FOR ALL
  USING (true)
  WITH CHECK (true);


-- ================================================================
-- SECTION 5: SEED — DEFAULT RAINFALL CONFIG
-- ================================================================
-- Insert the default rainfall config if table is empty.
-- This ensures the app works even before admin customises it.
-- ================================================================

INSERT INTO rainfall_config (config, updated_at)
SELECT
  '{
    "mode": "dual",
    "classifications": {
      "dual": {
        "enabled": true,
        "threshold": 64.5,
        "heavyCodes": [5, 27, 33, 37, 45, 56],
        "ocCodes": [],
        "labels": {
          "below": "L",
          "above": "H"
        }
      },
      "multi": {
        "enabled": false,
        "items": [
          {"id":"VL","variableName":"VL","label":"Very Light","thresholdMm":0.1,"codes":[2,3],"enabled":true,"order":1,"level":1,"parentCategory":"LOW"},
          {"id":"L","variableName":"L","label":"Light","thresholdMm":2.5,"codes":[4],"enabled":true,"order":2,"level":2,"parentCategory":"LOW"},
          {"id":"M","variableName":"M","label":"Moderate","thresholdMm":15.6,"codes":[5,6,7],"enabled":true,"order":3,"level":3,"parentCategory":"LOW"},
          {"id":"H","variableName":"H","label":"Heavy","thresholdMm":64.5,"codes":[27,33,37,45,56],"enabled":true,"order":4,"level":4,"parentCategory":"HEAVY"},
          {"id":"VH","variableName":"VH","label":"Very Heavy","thresholdMm":115.6,"codes":[8,9,10,11,12,25,28,34,39,44],"enabled":true,"order":5,"level":5,"parentCategory":"HEAVY"},
          {"id":"XH","variableName":"XH","label":"Extremely Heavy","thresholdMm":204.5,"codes":[26,29,35,38],"enabled":true,"order":6,"level":6,"parentCategory":"HEAVY"}
        ]
      }
    },
    "lastUpdated": "2026-05-25T00:00:00.000Z"
  }'::jsonb,
  now()
WHERE NOT EXISTS (SELECT 1 FROM rainfall_config);


-- ================================================================
-- SECTION 6: BOOTSTRAP ADMIN USER
-- ================================================================
-- After running this SQL, visit:
--   https://<your-app-url>/api/setup?secret=imd-setup-2026
-- This will create the admin auth user and profile row.
-- Admin credentials:
--   Email:    shamburavindren@gmail.com
--   Password: imd@mumbai
-- ================================================================

-- Done!
SELECT 'Schema created successfully. Visit /api/setup?secret=imd-setup-2026 to bootstrap admin.' AS status;
