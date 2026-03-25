-- Add spawned_by relationship type for tracking issue provenance
-- (e.g., when a task is spawned/created from another issue)
ALTER TYPE issue_relationship_type ADD VALUE IF NOT EXISTS 'spawned_by';
