-- Fix survey_responses RLS: Replace user_metadata (user-editable) with auth.uid() (tamper-proof)

-- Drop the insecure policies that use user_metadata
DROP POLICY IF EXISTS "Users can submit their own response" ON survey_responses;
DROP POLICY IF EXISTS "Users can read their own responses" ON survey_responses;

-- Re-create with secure auth.uid() + developers.claimed_by lookup
CREATE POLICY "Users can submit their own response" ON survey_responses
  FOR INSERT
  WITH CHECK (
    developer_id = (
      SELECT id FROM public.developers
      WHERE claimed_by = (select auth.uid())
      LIMIT 1
    )
  );

CREATE POLICY "Users can read their own responses" ON survey_responses
  FOR SELECT
  USING (
    developer_id = (
      SELECT id FROM public.developers
      WHERE claimed_by = (select auth.uid())
      LIMIT 1
    )
  );
