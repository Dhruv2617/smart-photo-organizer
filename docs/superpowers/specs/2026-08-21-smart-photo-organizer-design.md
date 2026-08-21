# Smart Photo/Video Organizer — Design Spec

## Problem

User takes many photos/videos daily, stored across multiple local drives (mac
internal + external drives). macOS Photos.app is not efficient for this:
requires importing into its own library (no in-place multi-drive indexing),
its duplicate detection is exact/near-exact only (misses burst shots,
re-compressed copies, cross-drive duplicates), and it gives no control over
where files physically live. Goal: a mac-first app that connects to arbitrary
local folders/drives, indexes photos+videos in place, detects true duplicates
(including near-duplicates), and identifies faces — without importing or
moving files.

## Platform & Scope

- **Platform**: macOS first (native Swift/SwiftUI). Windows port explicitly
  deferred — not designed for now, revisit after mac version is solid.
- **Scale**: arbitrary — from ~10k to 100k+ files, across multiple
  simultaneously or sequentially connected folders/drives (including
  removable drives that may go offline).
- **File operations**: v1 is **index + report only**. The app never moves,
  renames, or deletes files automatically. It surfaces duplicate clusters and
  face groupings for the user to review; any resulting file action is manual
  (via Finder or a future v2 feature). This removes the need for undo/trash
  safety mechanisms in v1.

## Architecture

Three subsystems, all reading/writing a local index database; raw media
files are never copied, moved, or modified.

1. **Indexer** — scans connected folders, extracts metadata, computes
   hashes, writes to index DB. Runs incrementally.
2. **Dedup engine** — consumes indexed hashes/embeddings, clusters
   duplicates/near-duplicates.
3. **Face engine** — consumes indexed face embeddings, clusters and matches
   against user-labeled identities.

The Gallery UI reads only from the index DB (metadata + cached thumbnails);
it touches original files only to generate thumbnails and to open/reveal
them in Finder.

## Data Flow

1. User adds a folder/drive as a "source" in the app.
2. Indexer walks the source, and for each new/changed image or video:
   - Computes SHA256 (exact-match fast path).
   - Computes perceptual hash (pHash) for images; for videos, samples
     frames (~every 2s) and pHashes each sampled frame.
   - Runs Apple Vision face detection on images (and on sampled video
     frames), storing face bounding boxes + embeddings.
   - Writes a row to the index DB: path, source/volume ID, file hash, pHash,
     capture date, face embedding refs.
3. Dedup engine groups files by exact hash first, then clusters remaining
   files by pHash similarity (threshold-based) into duplicate clusters,
   including cross-source clusters (same photo on two different drives).
4. Face engine matches new face embeddings against existing labeled
   identities (cosine similarity threshold); unmatched faces form "unnamed"
   clusters awaiting a user label. Once a user labels a cluster, all past
   and future matching faces inherit that label.
5. Gallery UI presents: all-photos view, duplicate-clusters view (grouped,
   with easiest-to-keep suggested), and per-person view (faces).

## Duplicate Detection

- **Exact duplicates**: SHA256 match — byte-identical files regardless of
  name/path/source.
- **Near duplicates**: pHash/dHash distance below threshold — catches burst
  shots, resized or re-compressed copies (e.g. messaging-app re-saves),
  minor crops/edits.
- **Videos**: near-duplicate detection via frame-sampled pHash sets;
  two videos are clustered as duplicates when a high proportion of sampled
  frames match within threshold.
- Duplicate clusters can span multiple connected drives/sources — this is
  the main gap vs Photos.app, which cannot dedupe across independent
  libraries/folders.
- The app never auto-deletes; it surfaces clusters with a suggested keeper
  (e.g. highest resolution, most complete metadata) and lets the user decide.

## Face Identification

- Uses Apple's Vision framework (`VNDetectFaceRectangles`, face landmarks/
  embeddings) — no external ML dependency needed on mac.
- User tags a face once with a name; the embedding is stored as that
  identity's reference. New indexed photos/videos are matched against all
  known identities automatically.
- Faces that don't match any known identity are grouped into unnamed
  clusters for the user to label or ignore.
- Videos are treated like photos for face purposes: sampled frames run
  through the same detection/embedding/matching pipeline, and a video is
  tagged with every identity found across its samples.

## Storage & Multi-Drive Handling

- Index DB: SQLite (via GRDB) storing file path (relative to its source),
  source/volume identifier, file hash, pHash, capture date, duplicate
  cluster ID, and face embedding + label references.
- Thumbnails cached separately under the app's Caches directory, keyed by
  file hash (survives file moves within a source, avoided regeneration).
- Each connected drive/source is identified by its volume UUID (stable
  across remounts) so the app can distinguish "same file on two drives" from
  "drive currently unavailable."
- When a source drive is unmounted, its indexed entries remain browsable
  (metadata + cached thumbnails) but are marked offline; scanning, new
  dedup/face matching involving that source's live files pause until it's
  remounted.

## Error Handling

- Unreadable/corrupt files: logged and skipped, do not halt the scan.
- Drive removed mid-scan: current scan pass for that source aborts
  cleanly, resumes from last known state on remount (incremental, not
  full rescan).
- Face detection or hashing failure on an individual file: file is still
  indexed with available metadata; face/dedup fields left null and retried
  on next scan pass.

## Testing

- Unit tests for hash/pHash/similarity-threshold logic using known
  duplicate and known-distinct photo pairs (including edited/re-compressed
  variants) to validate threshold choices.
- Unit tests for face-matching threshold using a small labeled set of
  same-person/different-person embedding pairs.
- Manual end-to-end test: connect a real external drive with a mixed
  photo/video library, confirm scan completes, duplicate clusters are
  correct (including a manually-planted cross-drive duplicate), and face
  tagging correctly recognizes a labeled person across multiple photos.

## Explicitly Out of Scope (v1)

- Automatic file operations (move/rename/delete) — future v2 consideration.
- Windows support — future port after mac version is validated.
- Cloud storage sources (iCloud, Google Photos, etc.) — local drives only.
