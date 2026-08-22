import Foundation

/// Central lookup for the bundled CLIP resources, so both production code
/// (`TextEmbedder`, `ImageEmbedder`) and tests resolve the same files from
/// this target's bundle — `Bundle.module` only resolves correctly from
/// within this module, so the test target (a different bundle) can't call
/// it directly and must go through this instead.
enum CLIPResources {
    static func imageEncoderCompiledURL() -> URL? {
        Bundle.module.url(forResource: "ImageEncoder", withExtension: "mlmodelc", subdirectory: "CLIPModels")
    }

    static func textEncoderCompiledURL() -> URL? {
        Bundle.module.url(forResource: "TextEncoder", withExtension: "mlmodelc", subdirectory: "CLIPModels")
    }

    static func tokenizerURLs() -> (vocab: URL, merges: URL)? {
        guard let vocabURL = Bundle.module.url(forResource: "vocab", withExtension: "json", subdirectory: "CLIPModels/Tokenizer"),
              let mergesURL = Bundle.module.url(forResource: "merges", withExtension: "txt", subdirectory: "CLIPModels/Tokenizer") else {
            return nil
        }
        return (vocabURL, mergesURL)
    }
}
