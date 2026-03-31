# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
bal build

# Run - import all open issues
bal run -- all

# Run - import specific issues by number
bal run -- 123 456 789

# Run - import issues with a specific label
bal run -- label=bug
```

Configuration is provided via `Config.toml` (excluded from git):
```toml
githubToken = "<PAT>"
sourceRepo = "owner/repo"
targetRepo = "owner/repo"
closeSourceIssue = false
addTargetLabels = []
addSourceLabels = []
```

## Architecture

Single-file Ballerina application (`main.bal`) that migrates GitHub issues between repositories using the `ballerinax/github` connector.

**Flow:**
1. `main()` parses CLI args (`all`, `label=<name>`, or issue numbers) and calls `importIssues()` or `importIssue()` per issue
2. `importIssue()` orchestrates a full migration: fetches source issue, creates it in target, then calls `importLabels()`, `importComments()`, `importAssignees()`
3. Optionally closes the source issue and adds labels to both repos via `labelAndCloseOriginalIssue()`

**Key behaviors:**
- Comments are re-created with markdown attribution (original author avatar + username + timestamp) since GitHub API doesn't allow posting as another user
- Labels missing in the target repo are auto-created with the same color/description
- Pull requests are filtered out when importing "all" issues via `filterOutPullRequests()`
- `RepoInfo` record holds `{owner, repo}` parsed from `"owner/repo"` strings
