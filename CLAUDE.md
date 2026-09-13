# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PhotoOrganizer — a native macOS (SwiftUI + Swift 6) app that indexes photos/videos in place across arbitrary local folders/drives (internal + external), without importing or moving files. It detects exact and near-duplicate media and (currently disabled) groups faces. See `docs/superpowers/specs/2026-08-21-smart-photo-organizer-design.md` for the full original design spec — it's the source of truth for *why* things work the way they do (duplicate/face matching rationale, multi-drive/offline handling, v1 scope boundaries).

Key v1 constraint from that spec: this app never moves, renames, or deletes original files. It only indexes and reports; any resulting file action is manual (Finder).

## Commands

Build:
```
swift build
```

Run:
```
swift run PhotoOrganizer
```

Test (all):
```
./swift-test.sh
```
Test (single filter):
```
./swift-test.sh --filter DatabaseManagerTests
```
Use `swift-test.sh`, not `swift test` directly — this machine has only Xcode Command Line Tools (no full Xcode/XCTest.framework), and the wrapper adds the `-F`/`-rpath` flags Swift Testing's `Testing.framework` needs in that configuration.

Package the app for distribution: no scripted build for `PhotoOrganizer.dmg`/`.app` exists in-repo (both are gitignored build output) — build/sign/package manually or via Xcode if you need a distributable artifact.

## Architecture

Three independent subsystems, all reading/writing one local GRDB/SQLite index (`DatabaseManager`); raw media files are never copied, moved, or modified by any of them:

1. **Indexer** (`Sources/PhotoOrganizer/Indexing/`) — walks a `Source` (a user-added folder/drive), and for each new/changed file: computes SHA256 (exact-dup fast path via `HashService`), computes a DCT-based perceptual hash (`HashService.pHash`) for photos or samples video frames every ~2s (`VideoFrameSampler`) and pHashes each, and (when face indexing is enabled) runs Vision face detection (`FaceDetector`) per photo/sampled frame. Writes rows to `mediaFile`/`faceObservation`. `Indexer.indexSource` is synchronous and safe to call off the main thread.
2. **Dedup engine** (`Sources/PhotoOrganizer/Dedup/DuplicateClusterer.swift`) — rebuilds all clusters from scratch each run: groups by exact SHA256 first (`matchType: "exact"`), then greedily clusters remaining files by pHash Hamming distance (`matchType: "near"`, threshold adjustable via a UI slider, default `DuplicateClusterer.defaultPHashThreshold`). Videos compare their *sets* of per-frame pHashes (via `frameOverlapFraction`) rather than a single hash. Clustering is cross-source (same file duplicated across two different drives lands in the same cluster) — this is the app's main advantage over Photos.app.
3. **Face engine** (`Sources/PhotoOrganizer/Faces/`) — `FaceDetector` produces a `VNFeaturePrintObservation` per detected face (archived to `Data`, since Vision has no public per-face float-embedding API); `FaceMatcher` unarchives and calls `computeDistance` against every known `FaceIdentity`, matching within `matchThreshold` or creating a new unnamed identity.

   **Face indexing is currently disabled** (`Indexer.faceIndexingEnabled = false`, and the People tab is commented out of the tab bar): `VNGenerateImageFeaturePrintRequest` (the only public Vision API) isn't face-recognition-tuned like Photos.app's private model, so it over-splits the same person into multiple identities. `PeopleView`/`PeopleViewModel` and the DB tables are untouched — re-enabling means flipping that flag back and re-adding the tab, not a rewrite.

UI (`Sources/PhotoOrganizer/UI/`) is SwiftUI, MVVM-ish (`SourcesViewModel`, `DuplicatesViewModel`, `PeopleViewModel` alongside their views), and reads only from the index DB plus generates thumbnails on demand — it never touches original files except to open/reveal them in Finder or run `MediaConverter` (photo/video format conversion into a separate destination folder, original left untouched).

`RootView` is a hand-rolled tab switcher (not a native `TabView`) so the tab bar can use a custom glossy icon look (`GlossyTabButton`) over `OceanBackground`; adding a tab means adding a case to the switch in `RootView`, not a `.tabItem`.

### Database

`DatabaseManager` owns a single `DatabasePool` (GRDB) at `~/Library/Application Support/PhotoOrganizer/index.sqlite`, migrated via a `DatabaseMigrator` with sequential `vN` migrations in `DatabaseManager.swift`. Add new schema changes as a new `vN` migration — never edit a past migration in place (GRDB tracks applied migrations by name/hash). Current tables: `source`, `mediaFile` (has `clusterId` back-reference, `pHash` stored as hex — comma-separated list of per-frame hashes for videos), `duplicateCluster` (with `matchType`), `faceIdentity`, `faceObservation`.

`Source` identity is by volume UUID (stable across remounts) with a folder-path fallback for volumes that don't report one (disk images, some network mounts) — this is how the app tells "same file on two drives" apart from "drive currently offline" (`SourceManager.refreshOnlineStatus`).

### Testing conventions

Tests live in `Tests/PhotoOrganizerTests/`, one file per subsystem/viewmodel, using Swift Testing (not XCTest). Hash/similarity-threshold tests use known duplicate/distinct photo pairs rather than asserting exact hash values.
