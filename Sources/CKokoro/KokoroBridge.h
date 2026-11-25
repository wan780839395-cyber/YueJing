#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct SherpaOnnxOfflineTts;
struct SherpaOnnxGeneratedAudio;

const struct SherpaOnnxOfflineTts *YJKokoroOpen(const char *directory, const char *modelName,
    bool normalizeNumbers);
void YJKokoroClose(const struct SherpaOnnxOfflineTts *tts);

// On success the view borrows from the returned owner until YJKokoroFreeAudio.
struct YJKokoroView {
    const float *samples;
    int32_t count;
    int32_t sampleRate;
};
const struct SherpaOnnxGeneratedAudio *YJKokoroGenerate(const struct SherpaOnnxOfflineTts *tts,
    const char *text, float speed, struct YJKokoroView *view);
void YJKokoroFreeAudio(const struct SherpaOnnxGeneratedAudio *audio);

#ifdef __cplusplus
}
#endif
