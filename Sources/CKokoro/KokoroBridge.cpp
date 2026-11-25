#include "KokoroBridge.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <string>

namespace {
constexpr int32_t sampleRate = 24000;
constexpr int32_t speaker = 3; // v1.1-zh generate_voices_bin.py: zf_001
constexpr int32_t maxSamples = 90 * sampleRate;

// Called synchronously once per sentence, before sherpa starts the next one.
int32_t withinBudget(const float *samples, int32_t n, void *arg) {
    auto &remaining = *static_cast<int32_t *>(arg);
    if (!samples || n < 0 || n > remaining) {
        remaining = -1;
        return 0;
    }
    remaining -= n;
    return 1;
}
}

const SherpaOnnxOfflineTts *YJKokoroOpen(const char *directory, const char *modelName,
                                        bool normalizeNumbers) {
    try {
        const std::string root = std::string(directory) + "/";
        const auto model = root + modelName, voices = root + "voices.bin", tokens = root + "tokens.txt";
        const auto data = root + "espeak-ng-data";
        const auto lexicons = root + "lexicon-zh.txt," + root + "lexicon-us-en.txt";
        const auto rules = root + "phone-zh.fst," + root + "date-zh.fst," + root + "number-zh.fst";
        SherpaOnnxOfflineTtsConfig config{};
        auto &k = config.model.kokoro;
        k.model = model.c_str();
        k.voices = voices.c_str();
        k.tokens = tokens.c_str();
        k.data_dir = data.c_str();
        k.lexicon = lexicons.c_str(); // leave lang empty: lexicon-based multilingual frontend
        k.length_scale = 1;
        config.model.num_threads = 2;
        config.model.provider = "cpu";
        // v1.12.20 replaces the entire utterance with each rule's output, even
        // if empty. Plain prose needs only the multilingual lexicon frontend.
        if (normalizeNumbers) config.rule_fsts = rules.c_str();
        config.max_num_sentences = 1;
        config.silence_scale = 1;
        auto *tts = SherpaOnnxCreateOfflineTts(&config);
        if (tts && (SherpaOnnxOfflineTtsSampleRate(tts) != sampleRate ||
                    SherpaOnnxOfflineTtsNumSpeakers(tts) != 103)) {
            SherpaOnnxDestroyOfflineTts(tts);
            return nullptr;
        }
        return tts;
    } catch (...) {
        return nullptr;
    }
}

void YJKokoroClose(const SherpaOnnxOfflineTts *tts) { SherpaOnnxDestroyOfflineTts(tts); }

const SherpaOnnxGeneratedAudio *YJKokoroGenerate(const SherpaOnnxOfflineTts *tts,
        const char *text, float speed, YJKokoroView *view) {
    try {
        if (!text || !*text) return nullptr;
        int32_t remaining = maxSamples;
        auto *audio = SherpaOnnxOfflineTtsGenerateWithCallbackWithArg(tts, text, speaker, speed,
                                                                     withinBudget, &remaining);
        if (!audio) return nullptr;
        if (remaining < 0 || !audio->samples || audio->n <= 0 || audio->n > maxSamples ||
            audio->sample_rate != sampleRate) {
            YJKokoroFreeAudio(audio);
            return nullptr;
        }
        *view = {audio->samples, audio->n, audio->sample_rate};
        return audio;
    } catch (...) {
        return nullptr;
    }
}

void YJKokoroFreeAudio(const SherpaOnnxGeneratedAudio *audio) {
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
}
