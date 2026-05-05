-- Patch: Fix items that failed during initial migration run

-- 1. Add missing github_etag column to developers
ALTER TABLE developers ADD COLUMN IF NOT EXISTS github_etag text;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS suspended boolean DEFAULT false;

-- 2. Fix count_ad_countries function (ad_id is uuid in sky_ad_events)
CREATE OR REPLACE FUNCTION count_ad_countries(p_ad_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT count(distinct country)::integer
  FROM sky_ad_events
  WHERE ad_id = p_ad_id::text
    AND country IS NOT NULL
    AND country != '';
$$;

-- 3. Re-apply the security hardening that was inside the rolled-back transaction
-- Set search_path on functions that exist
DO $$ BEGIN ALTER FUNCTION heartbeat_visitor(text) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION increment_hired_count(uuid) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION increment_job_counter(uuid, text) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION increment_kudos_count(bigint) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION increment_referral_count(bigint) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION increment_visit_count(bigint) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION recalculate_ranks() SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION refresh_sky_ad_stats() SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION spend_pixels(bigint, text, text, bigint, boolean, inet, text) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN ALTER FUNCTION upsert_arcade_visit(uuid, uuid) SET search_path = 'public'; EXCEPTION WHEN undefined_function THEN NULL; END $$;

-- 4. Revoke EXECUTE on security-critical functions from PUBLIC (was in rolled-back block)
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION assign_new_dev_rank(bigint) FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION credit_pixels(bigint, bigint, text, text, text, text, text, inet, text) FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION deactivate_expired_ads() FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION debit_pixels(bigint, bigint, text, text, text, text) FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION earn_pixels(bigint, text, text, text, text) FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION find_auth_user_by_github_login(text) FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION recalculate_ranks() FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN REVOKE EXECUTE ON FUNCTION refresh_sky_ad_stats() FROM PUBLIC; EXCEPTION WHEN undefined_function THEN NULL; END $$;

-- 5. Drop duplicate index (was in rolled-back block)
DROP INDEX IF EXISTS idx_dev_achievements_dev;

-- 6. Create city-data storage bucket hint
-- NOTE: You must manually create a 'city-data' public storage bucket in the Supabase dashboard
-- Dashboard -> Storage -> New Bucket -> Name: city-data -> Public: ON
