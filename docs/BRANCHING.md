# Voix — Branching Strategy

A fork of an actively-maintained upstream, worked by a small team. The strategy exists to answer two
questions: *where does new work go*, and *how do we take upstream's bug fixes without a merge
nightmare six months from now*.

Everything else is deliberately absent. No `develop` branch, no release branches, no gitflow. Tag
`main` when you ship.

## Branches

| Branch | Lives | Purpose |
|---|---|---|
| `main` | forever | Voix trunk. Always builds via `./build.sh unsigned`. |
| `phase/<n>-<slug>` | one phase | Work from the v1 plan. Squash-merged into `main`, then deleted. |
| `sync/upstream-<yyyy-mm-dd>` | one sync | Merges `upstream/main` into our history. Deleted after merge. |
| `fix/<slug>` | one bug | Post-v1 bug fixes. Same lifecycle as a phase branch. |

Remotes:

```
origin     https://github.com/stalinzbb/voix.git            # ours, push here
upstream   https://github.com/altic-dev/FluidVoice.git      # read-only, never push
```

The tag `fork-point` marks commit `1b070a8` — the last commit Voix shares with upstream before any
fork work. `git diff fork-point..main` is the complete Voix delta at any time, which is the single
most useful thing to hand someone reviewing the fork.

## Phase branches

The v1 plan has seven phases. Branch names are fixed in advance so the mapping from plan to git is
unambiguous:

```
phase/0-fork-hygiene        # de-phone-home, bundle ID, remove dictation-only UI
phase/2-speech-analysis     # SpeechAnalysisService + synthetic-PCM unit tests
phase/1-asr-seam            # forPracticeSession: parameter on ASRService.stop()
phase/3-practice-session    # PracticeSessionService orchestration
phase/5-practice-store      # PracticeSessionStore persistence
phase/6-practice-ui         # PracticeView + ContentView wiring
phase/4-coach-prompt        # prompt iteration against real recordings
```

They are listed in **execution order, not numeric order**. Phase 2 comes second because
`SpeechAnalysisService` is pure functions over `[Float]` with no app dependencies — it can be
written and fully tested before anything touches the monolith, which means the riskiest new code is
proven before the inherited code is disturbed. Phase 4 comes last because a coaching prompt can only
be tuned once there are real recordings and real metrics to tune it against.

Phases 1, 3, and 5 are a single unit of work in practice — the seam, the orchestrator, and the store
only become testable together, behind a debug button. Merge them as three branches or one, but
expect them to land at the same time.

Create branches when you start them, not upfront. An empty branch is a stale branch.

```bash
git switch main && git pull && git switch -c phase/0-fork-hygiene
```

Merge with squash, so `main` reads as one commit per phase:

```bash
git switch main && git merge --squash phase/0-fork-hygiene && git commit
git branch -d phase/0-fork-hygiene
```

## Stacked branches

Phases often depend on each other, and waiting for review before starting the next one wastes the
sequencing. Branch the next phase off the current one and open its PR against that parent rather
than `main`, so each PR's diff shows only its own phase instead of replaying everything beneath it.

Two things about that arrangement are easy to get wrong, and both were learned the hard way:

**Do not delete a branch that another open PR is stacked on.** Merging with "delete branch" — the
default in `gh pr merge --delete-branch` and in the GitHub UI — races the automatic retarget, and
the stacked PR is **closed** rather than moved to `main`. GitHub then refuses to reopen it, because
its base branch no longer exists, and refuses to retarget it, because it is closed. The only way
out is opening a replacement PR, which loses the review history. Keep the branch; retarget the
stacked PR to `main` afterwards, then delete it.

**Restack after every squash-merge.** Squashing creates a *new* commit, so a branch stacked on the
old one no longer descends from anything in `main`. Left alone, its PR diff replays the parent
phase's changes on top of its own. Rebase it before anyone reads that diff:

```bash
git fetch origin && git switch phase/6-practice-ui
git rebase origin/main          # drops the already-applied parent commit automatically
git push --force-with-lease origin phase/6-practice-ui
```

The rebase reports `skipped previously applied commit` — that is the parent phase being recognized
in `main`, not a problem. Use `--force-with-lease` rather than `--force`, so a push that would
discard someone else's work fails instead of succeeding quietly.

## `main` guarantees

One rule, and it is the only rule worth enforcing: **`main` always builds.** `./build.sh unsigned`
succeeds and the existing test target passes on every commit to `main`. That is what makes it safe
to merge upstream into it at any moment, and it is why phase work happens on branches even when the
diff is small.

`main` does not have to be feature-complete or pretty. It has to compile.

## Syncing with upstream

Upstream is 15 commits ahead as of the fork point and will keep moving. Voix wants its audio-stack
and ASR fixes; Voix does not want its auto-updater back.

**Merge, never rebase.** Merging keeps the shared ancestry intact, so the next sync only has to
consider commits that appeared since the last one. Rebasing Voix onto upstream would rewrite our
commits on every sync and make each one progressively more painful — the exact merge nightmare the
strategy is meant to avoid.

```bash
git fetch upstream
git switch -c sync/upstream-$(date +%F) main
git merge upstream/main
# resolve, then verify before it touches main:
./build.sh unsigned
git switch main && git merge --no-ff sync/upstream-$(date +%F)
git branch -d sync/upstream-$(date +%F)
```

Sync when there's a reason — an upstream fix you want, or a phase boundary — not on a schedule.
Mid-phase syncs stack an unrelated conflict resolution on top of unfinished work.

### The conflicts to expect

Phase 0 edits and upstream changes will collide in predictable places. Know the resolution before
you hit it:

- **`AppDelegate.swift`** — we removed the auto-update check and its retry timer. If upstream
  touches that region, take **ours** (keep it removed). Re-adding the updater points Voix at
  FluidVoice releases and it will replace itself with upstream on next launch.
- **`Info.plist`** — the PostHog key stays blank. Take **ours**.
- **`project.pbxproj`** — bundle identifier and product name stay Voix. Take **ours** for those
  keys, take upstream for build settings, file references, and target membership. Read this one
  hunk by hunk; pbxproj conflicts resolved carelessly break the project file.
  Note that `PRODUCT_NAME` is load-bearing beyond the app filename: it feeds `TEST_HOST` and
  `BUNDLE_LOADER` (which hardcode the `.app` path) and the Swift module name that tests
  `@testable import`. Voix builds `Voix Debug.app` / module `Voix_Debug`; if upstream touches any
  of those three, keep ours in all three or the test target stops building.
- **`SimpleUpdater.swift`** — keep the `selfReplacementEnabled = false` switch and both guards
  (top of `checkAndUpdate`, top of `performSwapAndRelaunch`). If upstream restructures either
  function, re-apply the guards to the new shape. Losing them re-arms self-replacement, and every
  inherited caller still passes `owner: "altic-dev"`.
- **`Tests/…/*.swift`** — the `@testable import Voix_Debug` lines. Upstream's say
  `FluidVoice_Debug`; take ours. Only the import lines differ, and the literal string
  `"FluidVoice"` appears in test *fixtures* where it is data, not a name to update.
- **`ContentView.swift`** — sidebar region. Ours removes Command Mode and adds `.practice`; upstream
  may add its own items. This is a genuine **both-sides** merge, not a take-one.
- **`ASRService.swift`** — the `forPracticeSession:` parameter on `stop()` and its two effects
  (skip filler removal, always snapshot). Keep ours, layered onto whatever upstream did around it.
  If upstream restructured `stop()`, re-apply the seam to the new shape rather than forcing the old
  diff — it is roughly ten lines and re-deriving it is faster than untangling a bad merge.

The four new files (`SpeechAnalysisService`, `PracticeSessionService`, `PracticeSessionStore`,
`PracticeView`) can never conflict. That is not an accident — it is why the plan is shaped as four
new files plus a handful of surgical edits rather than a refactor. **Every time you are tempted to
restructure inherited code, you are trading a one-time convenience for a permanent merge tax.**

## Releases

Tag `main`: `v1.0.0`, `v1.1.0`. No release branches — if v1.0.1 is needed, branch `fix/` from the
tag and merge forward.

Do not reuse upstream's version numbers. FluidVoice is at 1.6.x; Voix v1 is Voix's first release and
sharing a number with a different application would be confusing in bug reports.
