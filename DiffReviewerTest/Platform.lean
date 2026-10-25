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

/-- A model change without a migration fails here rather than on a deployment. -/
def theMigrationsBuildTheDeclaredSchema : Test := do
  match Db.Migration.planSteps Store.migrations Store.target with
  | .error e => return #[s!"the schema could not be diffed: {e}"]
  | .ok []   => return #[]
  | .ok steps => return #[s!"the declared schema is {steps.length} step(s) ahead of the \
migrations; add a migration to `DiffReviewer.Store.migrations`"]

def all : List (String × Test) :=
  [("reviewRoundTrips", reviewRoundTrips),
   ("isoOfEpochIsUtc", isoOfEpochIsUtc),
   ("slugPartsAreChecked", slugPartsAreChecked),
   ("transitionsAreTheOnesAPersonMakes", transitionsAreTheOnesAPersonMakes),
   ("theMigrationsBuildTheDeclaredSchema", theMigrationsBuildTheDeclaredSchema)]

end DiffReviewerTest.Platform