# Local fork — "懂的都懂" (chain-hop) feature

This fork tracks `cake-tech/cake_wallet` and adds a single self-contained
feature. Everything below is designed so `git pull` of upstream stays cheap.

## What was added

**New files (no upstream counterpart — never conflict):**

```
lib/core/hop/hop_engine.dart              scheduler (persist + resume + relay gate)
lib/core/hop/hop_planner.dart             random amount split + random delays
lib/core/hop/hop_executor_impl.dart       send / bridge / exchange execution
lib/core/hop/hop_exchange_service.dart    exchange provider pool
lib/entities/hop_task.dart                HopTask model + sqlite CRUD
lib/entities/hop_step.dart                HopStep model + sqlite CRUD
lib/view_model/hop/hop_view_model.dart    UI state + plan builder
lib/src/screens/hop/hop_page.dart         settings UI
```

**Upstream files touched (all *additive only*, zero deletions):**

| File | Change | Conflict risk |
|---|---|---|
| `cw_core/lib/db/sqlite.dart` | `_ensureLocalTables(db!)` call + table builders | **none** — schema version untouched |
| `lib/core/background_sync.dart` | one `HopEngine.runOnce()` call in `sync()` | low |
| `lib/di.dart` | 4 imports + 2 registrations | low (upstream edits other regions) |
| `lib/main.dart` | 1 import + `HopEngine.start()` after `isAppRunning = true;` | low |
| `lib/router.dart` | 1 import + `case Routes.hopPage` | low |
| `lib/routes.dart` | 1 constant | none |
| `lib/src/screens/settings/other_settings_page.dart` | 1 list row | low |
| `.gitignore` | ignore `.codegraph/` | none |

### Why the DB change is version-free

Earlier the feature bumped the sqlite schema version. That collides every time
upstream adds its own migration. It now creates its tables **idempotently on
every start**:

```dart
// in _initDb(), right after openDatabase(...)
await _ensureLocalTables(db!);

Future<void> _ensureLocalTables(Database db) async {
  await _createHopTaskTable(db);          // CREATE TABLE IF NOT EXISTS
  await _createHopStepTable(db);
  await _addColumnIfNotExists(db, table: 'HopStep', column: 'source_wallet_name', definition: 'TEXT');
  await _addColumnIfNotExists(db, table: 'HopStep', column: 'settled_at', definition: 'INTEGER');
}
```

No `version:` change, no `onUpgrade` block, nothing for upstream to fight with.

## How to pull upstream safely

### One-time: commit the feature

```bash
git checkout -b local/hop          # keep the fork work on its own branch
git add .gitignore \
        lib/core/hop lib/entities/hop_task.dart lib/entities/hop_step.dart \
        lib/view_model/hop lib/src/screens/hop
git commit -m "feat(local): 懂的都懂 chain-hop"
git add -p                          # commit the tracked edits separately
git commit -m "feat(local): wire chain-hop into di/router/settings/db"
```

Working on a branch is what keeps `git pull origin dev` predictable.

### Every time you want upstream

```bash
./fork/sync-upstream.sh
```

That script fetches `origin/dev`, rebases your local commits on top, and — if a
conflict lands in one of the wiring hunks — tells you exactly which marker to
resolve.

### If you'd rather not rebase

```bash
git fetch origin dev
git merge origin/dev
```

Because every local change is additive, a merge auto-resolves almost always.
The only files that can genuinely conflict are the ones upstream also edits in
the *same region*: `lib/di.dart` and `lib/router.dart`. Both are pure import +
registration inserts, so the fix is "keep both blocks" — delete no braces.

### Reapplying the wiring onto a fresh upstream checkout

If you ever blow the tree away and want to rebuild the fork:

```bash
git apply fork/patches/0001-hop-upstream-edits.patch
# then copy the untracked lib/core/hop, lib/entities/hop_*, lib/view_model/hop,
# lib/src/screens/hop files back in
```

The patch is regenerated with:

```bash
git diff > fork/patches/0001-hop-upstream-edits.patch
```

## Conflict cheat-sheet

| If the merge marker is around… | Do this |
|---|---|
| `openDatabase(..., version: N` | take **upstream's** version number; our tables are version-free |
| `import 'package:cake_wallet/...'` in `di.dart` / `router.dart` | keep **both** import lines |
| `getIt.registerFactory` block in `di.dart` | keep **both** registrations |
| `case Routes.xxx:` in `router.dart` | keep **both** cases |
| `static const xxx = '...'` in `routes.dart` | keep **both** constants |
| `ListItemRegularRow(...)` list in `other_settings_page.dart` | keep **both** rows |
| `isAppRunning = true;` in `main.dart` | keep upstream line, then our `HopEngine.start()` |
| `_syncWallets();` in `background_sync.dart` | keep upstream call, our tick goes before it |

## Feature notes for the next person

- The scheduler is **disk-backed**: kill the app mid-run and it resumes.
- `HopStep.sourceWalletName` is what makes multi-wallet relay work. When it is
  null the task wallet sends.
- Foreground ticks every 30 s; the background entry point ticks once per
  `BackgroundSync.sync()`.
- Cross-chain hops use the built-in USDT0/LayerZero bridge; cross-asset hops use
  the exchange providers listed in `hop_exchange_service.dart`.
- A hop in relay mode may only fire after the previous hop is `completed` —
  that gate lives in `HopEngine.runOnce`.

## Automated upstream sync (GitHub Actions)

`.github/workflows/sync-upstream.yml` runs on this fork:

- **daily** at 03:17 UTC
- **manually** via *Actions → Sync upstream → Run workflow*

Two jobs:

| Job | Does |
|---|---|
| `mirror` | fast-forwards this fork's `dev` branch to `cake-tech/cake_wallet:dev`, so `git diff dev` always equals our local delta |
| `sync` | merges `upstream/dev` into `local/hop`, verifies our wiring survived, refreshes `fork/patches`, pushes |

**It never pushes a broken tree.** If the merge conflicts, the job aborts the
merge, opens/updates a `upstream-sync` issue listing the conflicting files, and
fails the run.

### Manual run

```bash
gh workflow run sync-upstream.yml --repo youugiuhiuh/cake_wallet \
  -f upstream_ref=dev -f feature_branch=local/hop

# rehearse without pushing:
gh workflow run sync-upstream.yml --repo youugiuhiuh/cake_wallet -f dry_run=true
```

### What the sync verifies after every merge

`hopPage` in `routes.dart`, `Routes.hopPage` in `router.dart`, `HopEngine` in
`di.dart` / `main.dart` / `background_sync.dart`, the settings row, and
`_ensureLocalTables` in `sqlite.dart` — plus the eight new feature files. If any
marker is missing the job fails before pushing, so a bad merge can never quietly
drop the feature.

### Fork default branch

The fork's default branch is **`local/hop`**, not `dev`. `schedule`-triggered
workflows only run from the default branch, so this is what makes the daily sync
fire. `dev` stays a pristine mirror of upstream.

### First run result

Verified end-to-end against a 56-commit upstream jump: **clean auto-merge, zero
conflicts**, all wiring markers intact, patch regenerated.
