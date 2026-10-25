import DiffReviewer
import DiffReviewerTest.Basic

open Lean (Json)
open DiffReviewer

namespace DiffReviewerTest.Platform

def reviewRoundTrips : Test := do
  let r : Review :=
    { decision := .requestChanges, body := "Two things."
    , comments := [{ file := "A.lean", range := { startLine := 3, endLine := 5 }, body := "rename"
                   , suggestion := some "def foo := 1" }] }
  match Review.ofJsonString r.toJsonString with
  | .ok back => return check (back == r) "a review read back differs from the one written"
  | .error e => return #[s!"a review did not read back: {e}"]

def isoOfEpochIsUtc : Test := do
  return checkEq (isoOfEpoch 0) "1970-01-01T00:00:00Z" "the epoch"
    ++ checkEq (isoOfEpoch 951782400) "2000-02-29T00:00:00Z" "a leap day"
    ++ checkEq (isoOfEpoch 1792866501) "2026-10-24T18:28:21Z" "a recent instant"

def slugPartsAreChecked : Test := do
  return check (validSlugPart "mathlib4") "a plain name"
    ++ check (validSlugPart "lean-biscuit.v2") "dashes and dots"
    ++ check (!validSlugPart "") "the empty name"
    ++ check (!validSlugPart "..") "a parent directory"
    ++ check (!validSlugPart ".hidden") "a leading dot"
    ++ check (!validSlugPart "a/b") "a separator"

def transitionsAreTheOnesAPersonMakes : Test := do
  return check (JobStatus.draft.personCanMove .approved) "a draft is approved"
    ++ check (!JobStatus.approved.personCanMove .posted) "posting is the platform's"
    ++ check (!JobStatus.pending.personCanMove .approved) "nothing to approve before a draft"
    ++ check (!JobStatus.running.personCanEdit) "not while the agent writes"
    ++ check (!JobStatus.posted.personCanEdit) "a posted review is history"
    ++ check (JobStatus.failed.personCanMove .pending) "a failed run is retried"
    ++ check (!JobStatus.running.personCanMove .failed) "failing a run is the platform's"
    ++ check (!JobStatus.failed.personCanMove .draft) "a failed run has no draft"
    ++ checkEq (JobStatus.ofString? "failed") (some .failed) "the new status reads back"

/-- A model change without a migration fails here rather than on a deployment. -/
def theMigrationsBuildTheDeclaredSchema : Test := do
  match Db.Migration.planSteps Store.migrations Store.target with
  | .error e => return #[s!"the schema could not be diffed: {e}"]
  | .ok []   => return #[]
  | .ok steps => return #[s!"the declared schema is {steps.length} step(s) ahead of the \
migrations; add a migration to `DiffReviewer.Store.migrations`"]

/-- A database `0001` built, with a row in it, is brought up to date on first use and its rows
    read as they were, with the new columns' defaults. -/
def anOldDatabaseIsMigrated : Test := withTempDb do
  let path ← Store.pathRef.get
  Sqlite.runDB path do
    let _ ← Db.Migration.migrate [Store.migration0001] 0
    let db ← read
    SQLite.exec db "INSERT INTO repo (owner, name, mode, created_at) VALUES \
('acme', 'widgets', 'direct', '2026-01-01T00:00:00Z')"
    SQLite.exec db "INSERT INTO review_job (id, owner, name, pr_number, head_sha, status, \
queue_entry, review, version, created_at, updated_at) VALUES ('j1', 'acme', 'widgets', 7, NULL, \
'draft', NULL, NULL, 3, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')"
  let repos ← Platform.listRepos
  let some job ← Platform.findJob "j1" | return #["the old job is gone"]
  return checkEq (repos.map (·.slug)) #["acme/widgets"] "the old repository"
    ++ check (repos.all (!·.autoReview)) "autoReview is off for an old row"
    ++ check (repos.all (·.mode == .direct)) "the old mode"
    ++ checkEq job.version 3 "the old job's version"
    ++ checkEq job.attempts 0 "no attempts for an old job"

def all : List (String × Test) :=
  [("reviewRoundTrips", reviewRoundTrips),
   ("isoOfEpochIsUtc", isoOfEpochIsUtc),
   ("slugPartsAreChecked", slugPartsAreChecked),
   ("transitionsAreTheOnesAPersonMakes", transitionsAreTheOnesAPersonMakes),
   ("theMigrationsBuildTheDeclaredSchema", theMigrationsBuildTheDeclaredSchema),
   ("anOldDatabaseIsMigrated", anOldDatabaseIsMigrated)]

end DiffReviewerTest.Platform