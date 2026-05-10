# Diff reviewer

This project contains a diff review tool suite. It contains the following components:

1. A dataformat (likely a JSON schema) representing a code review of a diff: This includes the decision (comment only / approve / request changes), a general review comment and a list of inline review comments attached to files and line number ranges.
2. Visualisation of the dataformat in 1 in a form similar to the github PR review page: Show the diff and annotate it with review comments. This should be available as a simple website (that can be served locally), where comments can still be modified. In the first version, only implement a read-only view.
3. Import the dataformat in 1 as a github review on a pull request.
4. Parse the dataformat from a commit history (this could be used to produce a review on github by making a list of commits). Every commit becomes one in-line review comment with the commit history as the comment and the diff as the suggestion.

## Notes for the implementation

- This is a Lean project.
- Prefer custom datatypes to increase type safety. Keep serialization and deserialization as
  simple as possible.
- Apache 2 license
