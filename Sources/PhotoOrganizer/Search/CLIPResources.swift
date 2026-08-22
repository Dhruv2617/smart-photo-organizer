import Foundation

/// Central lookup for the bundled CLIP resources. Deliberately does NOT use
/// SwiftPM's generated `Bundle.module` accessor — that accessor's fallback
/// path is an absolute path baked in at THIS machine's build time (e.g.
/// "/Users/you/project/.build/.../release/..."), which only happens to work
/// here because that directory exists on this machine. On a friend's Mac
/// running the packaged .app, that path doesn't exist, `Bundle.module`
/// hits its other candidate (the .app's own root, which isn't a valid
/// place to put resources in a properly *code-signed* .app — only
/// "Contents" may live at an .app's top level) — so it works during dev
/// but silently breaks for anyone else, only surfacing as a crash on a
/// machine we don't have access to. This resolves resources by checking
/// portable, machine-independent locations instead.
enum CLIPResources {
    /// Where the CLIPModels folder actually lives, checked in order:
    /// 1. `Contents/Resources/CLIPModels` — where a properly packaged,
    ///    code-signed `.app` should place it (this is `Bundle.main.resourceURL`).
    /// 2. Next to the running executable, inside the SwiftPM-generated
    ///    per-target resource bundle — covers `swift run` and `swift test`,
    ///    neither of which run from inside a real `.app`.
    private static func clipModelsDirectory() -> URL? {
        let fileManager = FileManager.default

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("CLIPModels")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let executableDirectory = Bundle.main.bundleURL
        let executableCandidate = executableDirectory
            .appendingPathComponent("PhotoOrganizer_PhotoOrganizer.bundle")
            .appendingPathComponent("CLIPModels")
        if fileManager.fileExists(atPath: executableCandidate.path) {
            return executableCandidate
        }

        // `swift test` runs inside an `xctest` host process whose own
        // `Bundle.main` has nothing to do with this package's build output
        // — the two checks above can't find anything in that context. This
        // is a dev/test-only fallback: #filePath is recomputed fresh at
        // every compile, on whichever machine is actually building+testing,
        // so it's not a hardcoded path baked for one specific developer's
        // machine — but it only ever applies during local test runs, never
        // to a distributed .app (which always resolves via the first check).
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Search/
            .deletingLastPathComponent() // PhotoOrganizer/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // package root
        for config in ["debug", "release"] {
            let candidate = packageRoot
                .appendingPathComponent(".build/\(config)/PhotoOrganizer_PhotoOrganizer.bundle/CLIPModels")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func imageEncoderCompiledURL() -> URL? {
        clipModelsDirectory()?.appendingPathComponent("ImageEncoder.mlmodelc")
    }

    static func textEncoderCompiledURL() -> URL? {
        clipModelsDirectory()?.appendingPathComponent("TextEncoder.mlmodelc")
    }

    static func tokenizerURLs() -> (vocab: URL, merges: URL)? {
        guard let dir = clipModelsDirectory() else { return nil }
        let vocabURL = dir.appendingPathComponent("Tokenizer/vocab.json")
        let mergesURL = dir.appendingPathComponent("Tokenizer/merges.txt")
        guard FileManager.default.fileExists(atPath: vocabURL.path),
              FileManager.default.fileExists(atPath: mergesURL.path) else {
            return nil
        }
        return (vocabURL, mergesURL)
    }
}
