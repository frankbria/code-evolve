# A refused push on GitHub Actions: the run fails, and no retry session starts

Recorded for [#145](https://github.com/frankbria/code-evolve/issues/145), item 9. The shell tests
check `evolve.yml`'s handling of exit status 4 by reading the file. This is one run of the
installed workflow on GitHub's runners.

- **Run:** <https://github.com/frankbria/code-evolve/actions/runs/43062576322> (2026-11-11,
  workflow "Evolution", conclusion `failure`, which is the expected result). GitHub keeps the
  log for 90 days; the step results and log lines below are copied from it.
- **Engine:** the one in this repository at commit `f6abaf9` (PR for #145).

## What ran

A new project with one `package.json`, set up with `code-evolve init --agent claude --with-ci --yes`
and pushed as a throwaway branch of this repository. The installed `.github/workflows/evolve.yml`
was changed in four places and nowhere else:

| Change | Why |
|---|---|
| `on:` is a push to the throwaway branch, not the schedule | A schedule or manual trigger only runs from the default branch |
| `permissions:` is `contents: read` only | This is the refusal: the token may not push. It may not write issues either |
| "Install agent CLI" writes a stand-in `claude` that reads the prompt and changes nothing | No agent session is needed to test the push handling, and none is paid for |
| `ANTHROPIC_API_KEY` is the text `stand-in` | No real key reaches the run |

The session step, both retry steps and the final step are the installed ones, unchanged:

```diff
@@ -2,14 +2,11 @@
 name: Evolution
 
 on:
-  schedule:
-    - cron: '0 */4 * * *'  # every 4h
-  workflow_dispatch:       # manual trigger
+  push:
+    branches: ['acceptance/issue-145-refused-push']
 
 permissions:
-  contents: write
-  issues: write
-  actions: read   # lets the engine read evolve-ci.yml's last run (gh run list)
+  contents: read
 
 jobs:
   evolve:
@@ -72,7 +69,11 @@
           java-version: '21'
 
       - name: Install agent CLI
-        run: npm install -g @anthropic-ai/claude-code
+        run: |
+          mkdir -p "$RUNNER_TEMP/bin"
+          printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$RUNNER_TEMP/bin/claude"
+          chmod +x "$RUNNER_TEMP/bin/claude"
+          echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
 
       - name: Setup GitHub CLI
         run: gh auth status
@@ -90,7 +91,7 @@
         env:
           GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
           # code-evolve:secrets — agent backend secrets (templated by init)
-          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
+          ANTHROPIC_API_KEY: stand-in
           CLAUDE_AUTH_MODE: api-key
           # code-evolve:secrets-end
         run: |
@@ -108,7 +109,7 @@
         env:
           GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
           # code-evolve:secrets — agent backend secrets (templated by init)
-          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
+          ANTHROPIC_API_KEY: stand-in
           CLAUDE_AUTH_MODE: api-key
           # code-evolve:secrets-end
         run: |
@@ -123,7 +124,7 @@
         env:
           GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
           # code-evolve:secrets — agent backend secrets (templated by init)
-          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
+          ANTHROPIC_API_KEY: stand-in
           CLAUDE_AUTH_MODE: api-key
           # code-evolve:secrets-end
         run: |
```

## Result

| Step | Result |
|---|---|
| Run evolution session | ran, engine exit status 4 (the step is `continue-on-error`, so GitHub lists it as passed) |
| Retry after 15min | **skipped** |
| Retry after 45min | **skipped** |
| Fail when a cycle was not pushed | **failed**, which fails the run |

From the session step's log:

```
  Committed session wrap-up.
-> Pushing...
  Tagged: day0-16-52
remote: Permission to frankbria/code-evolve.git denied to github-actions[bot].
fatal: unable to access 'https://github.com/frankbria/code-evolve/': The requested URL returned error: 403
  Push failed: fatal: unable to access 'https://github.com/frankbria/code-evolve/': The requested URL returned error: 403
  Removed tag day0-16-52: the session was not pushed.
=== Day 0 is committed locally but NOT pushed (exit status 4) ===
##[error]Process completed with exit code 4.
```

From the last step:

```
##[error]The cycle ran but its commits could not be pushed. See the lines after 'Pushing...' in the session step.
##[error]Process completed with exit code 1.
```

After the run the branch on GitHub was still at the pushed fixture commit (`ca3014f`), there was
no `day0-16-52` tag, and no issue had a new comment. The branch was deleted afterwards.

## Not covered

- A real agent session. The stand-in makes no changes, so the cycle's commits are the engine's own
  (journal entry, wrap-up).
- A push refused by a branch protection rule or by another scheduler's push. The refusal here is a
  token without write access. The engine treats every refused push the same way: the shell tests
  in `tests/test_finalize_push.sh` cover the other causes.
- The retry path for a status other than 4 (an agent failure). It was not exercised.
