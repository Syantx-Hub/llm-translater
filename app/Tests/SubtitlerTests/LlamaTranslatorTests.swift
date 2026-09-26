import Testing
@testable import Subtitler

@Suite struct LlamaTranslatorTests {
    @Test func detectsARepeatingTail() {
        let phrase: [Int32] = [5, 6, 7, 8, 9, 10, 11, 12]
        #expect(LlamaTranslator.isLooping([1, 2] + phrase + phrase))
    }

    @Test func ordinaryOutputIsNotALoop() {
        #expect(!LlamaTranslator.isLooping(Array(1...40)))
        #expect(!LlamaTranslator.isLooping([1, 2, 3]))
        // Repeated particles are normal in Burmese; only a whole repeated span counts.
        #expect(!LlamaTranslator.isLooping([7, 1, 7, 2, 7, 3, 7, 4, 7, 5, 7, 6, 7, 8, 7, 9]))
    }
}
