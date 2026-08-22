#ifndef GARY_AUDIO_CONVERTER_NATIVE_H_
#define GARY_AUDIO_CONVERTER_NATIVE_H_

#include <cstdint>

#if defined(_WIN32)
#if defined(GAC_AUDIO_ENGINE_EXPORTS)
#define GAC_API __declspec(dllexport)
#else
#define GAC_API __declspec(dllimport)
#endif
#else
#define GAC_API
#endif

extern "C" {

// design: 0 = Kaiser, 1 = weighted least squares.
// quality: 0 = Efficient, 1 = Studio, 2 = Mastering.
GAC_API int32_t gac_convert_wav(const wchar_t* input_path,
                                const wchar_t* output_path,
                                int32_t design,
                                int32_t quality,
                                double headroom_db,
                                int32_t output_bits,
                                int32_t noise_shaping,
                                int32_t tpdf_dither);
GAC_API double gac_get_progress();
GAC_API void gac_request_cancel();
GAC_API int32_t gac_copy_last_error(wchar_t* destination,
                                    int32_t capacity);

}

#endif  // GARY_AUDIO_CONVERTER_NATIVE_H_
