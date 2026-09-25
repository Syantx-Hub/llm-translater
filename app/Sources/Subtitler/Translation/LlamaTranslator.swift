import Foundation
import llama

enum LlamaError: LocalizedError {
    case loadFailed(String)
    case encodeFailed(Int32)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "Could not load the translation model at \(path)."
        case .encodeFailed(let code): "Translation model failed to read the input (\(code))."
        case .decodeFailed(let code): "Translation model failed while writing (\(code))."
        }
    }
}

/// Runs an encoder-decoder MADLAD-400 GGUF with llama.cpp on the GPU (Metal).
///
/// MADLAD chooses the output language from a "<2xx>" prefix on the input and detects
/// the source language itself, so one loaded model serves every pair.
actor LlamaTranslator: Translator {
    private let modelPath: String
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    private let maxInputTokens = 480
    private let maxOutputTokens = 256

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func start() async throws {
        guard model == nil else { return }
        Self.initBackend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.loadFailed(modelPath)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 1024
        // The encoder must see the whole input in a single physical batch.
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.loadFailed(modelPath)
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        self.model = model
        self.context = context
        self.sampler = chain
    }

    func translate(_ text: String, from source: String, to target: String, context lines: [String]) async throws -> String {
        guard let model, let context, let sampler else { throw LlamaError.loadFailed(modelPath) }
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        var input = tokenize("<2\(target)> \(text)", vocab: vocab)
        if input.count > maxInputTokens { input = Array(input.prefix(maxInputTokens)) }
        let encoded = input.withUnsafeMutableBufferPointer {
            llama_encode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }
        guard encoded == 0 else { throw LlamaError.encodeFailed(encoded) }

        var token = llama_model_decoder_start_token(model)
        if token == LLAMA_TOKEN_NULL { token = llama_vocab_bos(vocab) }
        var output: [llama_token] = []
        for _ in 0..<maxOutputTokens {
            let decoded = withUnsafeMutablePointer(to: &token) {
                llama_decode(context, llama_batch_get_one($0, 1))
            }
            guard decoded == 0 else { throw LlamaError.decodeFailed(decoded) }
            token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output.append(token)
            try Task.checkCancellation()
        }
        return detokenize(output, vocab: vocab).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() async {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
    }

    private func tokenize(_ text: String, vocab: OpaquePointer?) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(count, 0))))
    }

    private func detokenize(_ tokens: [llama_token], vocab: OpaquePointer?) -> String {
        var tokens = tokens
        var buffer = [CChar](repeating: 0, count: tokens.count * 16 + 16)
        var length = llama_detokenize(vocab, &tokens, Int32(tokens.count), &buffer, Int32(buffer.count), true, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length) + 1)
            length = llama_detokenize(vocab, &tokens, Int32(tokens.count), &buffer, Int32(buffer.count), true, false)
        }
        let bytes = buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// llama.cpp's global setup; runs once. Its logs are verbose, so only errors are kept.
    private static let initBackend: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            fputs(String(cString: text), stderr)
        }, nil)
        llama_backend_init()
    }()
}
