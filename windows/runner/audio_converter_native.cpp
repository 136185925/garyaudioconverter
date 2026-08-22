#include "audio_converter_native.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <fstream>
#include <limits>
#include <mutex>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr double kPi = 3.1415926535897932384626433832795;
constexpr uint32_t kUpsampleFactor = 4;
constexpr uint32_t kFramesPerBlock = 8192;

std::atomic<double> g_progress{0.0};
std::atomic<bool> g_cancel_requested{false};
std::mutex g_error_mutex;
std::wstring g_last_error;

struct WavInfo {
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  uint16_t block_align = 0;
  uint16_t bits_per_sample = 0;
  uint64_t data_offset = 0;
  uint64_t data_bytes = 0;
};

struct QualitySpec {
  uint32_t taps_44k;
  uint32_t taps_48k;
  double kaiser_beta;
};

constexpr QualitySpec kQualitySpecs[] = {
    {1024, 768, 10.5},
    {2048, 1536, 12.0},
    {10240, 7680, 14.5},
};

void SetError(const wchar_t* message) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = message == nullptr ? L"Unknown conversion error" : message;
}

void SetError(const std::wstring& message) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = message;
}

uint16_t ReadLe16(const uint8_t* data) {
  return static_cast<uint16_t>(data[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(data[1]) << 8);
}

uint32_t ReadLe32(const uint8_t* data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

bool ReadExact(std::istream& input, void* destination, std::streamsize size) {
  input.read(static_cast<char*>(destination), size);
  return input.good() || input.gcount() == size;
}

bool ParseWav(std::ifstream& input, WavInfo* info) {
  uint8_t riff_header[12] = {};
  if (!ReadExact(input, riff_header, sizeof(riff_header)) ||
      std::memcmp(riff_header, "RIFF", 4) != 0 ||
      std::memcmp(riff_header + 8, "WAVE", 4) != 0) {
    SetError(L"The selected file is not a RIFF/WAVE file.");
    return false;
  }

  bool found_format = false;
  bool found_data = false;
  uint16_t format_tag = 0;
  bool extensible_pcm = false;

  while (input.good() && (!found_format || !found_data)) {
    uint8_t chunk_header[8] = {};
    if (!ReadExact(input, chunk_header, sizeof(chunk_header))) break;
    const uint32_t chunk_size = ReadLe32(chunk_header + 4);
    const std::streamoff chunk_start = input.tellg();

    if (std::memcmp(chunk_header, "fmt ", 4) == 0) {
      const uint32_t bytes_to_read = std::min<uint32_t>(chunk_size, 64);
      std::vector<uint8_t> format(bytes_to_read);
      if (bytes_to_read < 16 ||
          !ReadExact(input, format.data(), bytes_to_read)) {
        SetError(L"The WAV format chunk is incomplete.");
        return false;
      }
      format_tag = ReadLe16(format.data());
      info->channels = ReadLe16(format.data() + 2);
      info->sample_rate = ReadLe32(format.data() + 4);
      info->block_align = ReadLe16(format.data() + 12);
      info->bits_per_sample = ReadLe16(format.data() + 14);
      extensible_pcm = format_tag == 0xFFFE && bytes_to_read >= 40 &&
                       ReadLe16(format.data() + 24) == 1;
      found_format = true;
    } else if (std::memcmp(chunk_header, "data", 4) == 0) {
      info->data_offset = static_cast<uint64_t>(chunk_start);
      info->data_bytes = chunk_size;
      found_data = true;
    }

    const uint64_t next_chunk =
        static_cast<uint64_t>(chunk_start) + chunk_size + (chunk_size & 1U);
    input.clear();
    input.seekg(static_cast<std::streamoff>(next_chunk), std::ios::beg);
  }

  if (!found_format || !found_data) {
    SetError(L"The WAV file does not contain both format and audio chunks.");
    return false;
  }
  if (format_tag != 1 && !extensible_pcm) {
    SetError(L"Only uncompressed PCM WAV input is supported.");
    return false;
  }
  if (info->bits_per_sample != 16 && info->bits_per_sample != 24) {
    SetError(L"Only 16-bit or packed 24-bit PCM WAV input is supported.");
    return false;
  }
  const uint16_t bytes_per_sample = info->bits_per_sample / 8U;
  if (info->channels == 0 || info->channels > 8 ||
      info->block_align != info->channels * bytes_per_sample) {
    SetError(L"The WAV channel layout is not supported.");
    return false;
  }
  if (info->sample_rate != 44100 && info->sample_rate != 48000) {
    SetError(L"FIR MIN accepts 44.1 kHz or 48 kHz source files.");
    return false;
  }
  info->data_bytes -= info->data_bytes % info->block_align;
  if (info->data_bytes == 0) {
    SetError(L"The WAV file contains no complete audio frames.");
    return false;
  }
  input.clear();
  input.seekg(static_cast<std::streamoff>(info->data_offset), std::ios::beg);
  if (!input.good()) {
    SetError(L"Unable to seek to the WAV audio data.");
    return false;
  }
  return true;
}

double BesselI0(double value) {
  const double x = value * value * 0.25;
  double sum = 1.0;
  double term = 1.0;
  for (int order = 1; order < 40; ++order) {
    term *= x / static_cast<double>(order * order);
    sum += term;
    if (term < sum * 1.0e-16) break;
  }
  return sum;
}

size_t NextPowerOfTwo(size_t value) {
  size_t result = 1;
  while (result < value) result <<= 1;
  return result;
}

void Fft(std::vector<std::complex<double>>* values, bool inverse) {
  std::vector<std::complex<double>>& data = *values;
  const size_t count = data.size();
  for (size_t source = 1, target = 0; source < count; ++source) {
    size_t bit = count >> 1;
    for (; target & bit; bit >>= 1) target ^= bit;
    target ^= bit;
    if (source < target) std::swap(data[source], data[target]);
  }

  for (size_t length = 2; length <= count; length <<= 1) {
    const double angle = (inverse ? 2.0 : -2.0) * kPi /
                         static_cast<double>(length);
    const std::complex<double> step(std::cos(angle), std::sin(angle));
    for (size_t offset = 0; offset < count; offset += length) {
      std::complex<double> rotation(1.0, 0.0);
      const size_t half = length >> 1;
      for (size_t index = 0; index < half; ++index) {
        const std::complex<double> even = data[offset + index];
        const std::complex<double> odd =
            data[offset + index + half] * rotation;
        data[offset + index] = even + odd;
        data[offset + index + half] = even - odd;
        rotation *= step;
      }
    }
  }

  if (inverse) {
    const double scale = 1.0 / static_cast<double>(count);
    for (std::complex<double>& value : data) value *= scale;
  }
}

double CosineIntegral(double frequency, double start, double end) {
  if (std::abs(frequency) < 1.0e-12) return end - start;
  return (std::sin(frequency * end) - std::sin(frequency * start)) /
         frequency;
}

double ShiftedCosineIntegral(double frequency,
                             double phase,
                             double start,
                             double end) {
  if (std::abs(frequency) < 1.0e-12) {
    return std::cos(phase) * (end - start);
  }
  return (std::sin(frequency * end + phase) -
          std::sin(frequency * start + phase)) /
         frequency;
}

double RaisedCosineIntegral(double frequency,
                            double passband_edge,
                            double stopband_edge) {
  const double transition_rate =
      kPi / (stopband_edge - passband_edge);
  const double phase = -transition_rate * passband_edge;
  const double cosine_product =
      0.5 *
      (ShiftedCosineIntegral(transition_rate - frequency, phase,
                             passband_edge, stopband_edge) +
       ShiftedCosineIntegral(transition_rate + frequency, phase,
                             passband_edge, stopband_edge));
  return 0.5 *
             CosineIntegral(frequency, passband_edge, stopband_edge) +
         0.5 * cosine_product;
}

double DotProduct(const std::vector<double>& left,
                  const std::vector<double>& right) {
  double sum0 = 0.0;
  double sum1 = 0.0;
  double sum2 = 0.0;
  double sum3 = 0.0;
  size_t index = 0;
  for (; index + 3U < left.size(); index += 4U) {
    sum0 += left[index] * right[index];
    sum1 += left[index + 1U] * right[index + 1U];
    sum2 += left[index + 2U] * right[index + 2U];
    sum3 += left[index + 3U] * right[index + 3U];
  }
  double result = (sum0 + sum1) + (sum2 + sum3);
  for (; index < left.size(); ++index) result += left[index] * right[index];
  return result;
}

bool DesignWeightedLeastSquaresPrototype(uint32_t taps,
                                         std::vector<double>* linear) {
  // Continuous-frequency weighted least squares. The lightly weighted
  // raised-cosine transition keeps the time response smooth, while the high
  // stopband weight minimizes total imaging energy rather than only the worst
  // individual sidelobe. The symmetric normal matrix is Toeplitz + Hankel, so
  // preconditioned conjugate gradient can apply it with FFT convolutions
  // instead of constructing a multi-gigabyte dense matrix in Mastering mode.
  constexpr double kTransitionFactor = 11.0;
  constexpr double kTransitionWeight = 0.1;
  constexpr double kStopbandWeight = 100000.0;
  constexpr uint32_t kMaximumIterations = 180;
  constexpr double kRelativeTolerance = 1.0e-10;

  const uint32_t half_taps = taps / 2U;
  const double cutoff = kPi * 0.25;
  const double half_transition = kPi * kTransitionFactor /
                                 static_cast<double>(taps);
  const double passband_edge = cutoff - half_transition;
  const double stopband_edge = cutoff + half_transition;

  std::vector<double> moments(taps);
  for (uint32_t order = 0; order < taps; ++order) {
    const double frequency = static_cast<double>(order);
    moments[order] =
        CosineIntegral(frequency, 0.0, passband_edge) +
        kTransitionWeight *
            CosineIntegral(frequency, passband_edge, stopband_edge) +
        kStopbandWeight *
            CosineIntegral(frequency, stopband_edge, kPi);
  }

  std::vector<double> right_hand_side(half_taps);
  const double center = (static_cast<double>(taps) - 1.0) * 0.5;
  for (uint32_t index = 0; index < half_taps; ++index) {
    const double frequency = center - static_cast<double>(index);
    right_hand_side[index] =
        2.0 *
        (CosineIntegral(frequency, 0.0, passband_edge) +
         kTransitionWeight * RaisedCosineIntegral(
                                 frequency, passband_edge, stopband_edge));
  }

  const size_t fft_size =
      NextPowerOfTwo(static_cast<size_t>(half_taps) * 4U);
  std::vector<std::complex<double>> toeplitz_spectrum(fft_size);
  toeplitz_spectrum[0] = moments[0];
  for (uint32_t index = 1; index < half_taps; ++index) {
    toeplitz_spectrum[index] = moments[index];
    toeplitz_spectrum[fft_size - index] = moments[index];
  }
  Fft(&toeplitz_spectrum, false);

  std::vector<std::complex<double>> hankel_spectrum(fft_size);
  for (uint32_t index = 0; index < taps; ++index) {
    hankel_spectrum[index] = moments[index];
  }
  Fft(&hankel_spectrum, false);

  const double regularization = moments[0] * 1.0e-12;
  std::vector<double> diagonal(half_taps);
  for (uint32_t index = 0; index < half_taps; ++index) {
    diagonal[index] =
        2.0 * (moments[0] + moments[taps - 1U - 2U * index]) +
        regularization;
  }

  std::vector<std::complex<double>> input_spectrum(fft_size);
  std::vector<std::complex<double>> toeplitz_result(fft_size);
  std::vector<std::complex<double>> hankel_result(fft_size);
  auto apply_normal_matrix = [&](const std::vector<double>& input,
                                 std::vector<double>* result) {
    std::fill(input_spectrum.begin(), input_spectrum.end(),
              std::complex<double>(0.0, 0.0));
    for (uint32_t index = 0; index < half_taps; ++index) {
      input_spectrum[index] = input[index];
    }
    Fft(&input_spectrum, false);
    for (size_t index = 0; index < fft_size; ++index) {
      toeplitz_result[index] =
          input_spectrum[index] * toeplitz_spectrum[index];
      hankel_result[index] =
          input_spectrum[index] * hankel_spectrum[index];
    }
    Fft(&toeplitz_result, true);
    Fft(&hankel_result, true);
    result->resize(half_taps);
    for (uint32_t index = 0; index < half_taps; ++index) {
      (*result)[index] =
          2.0 *
              (toeplitz_result[index].real() +
               hankel_result[taps - 1U - index].real()) +
          regularization * input[index];
    }
  };

  std::vector<double> solution(half_taps, 0.0);
  std::vector<double> residual = right_hand_side;
  std::vector<double> preconditioned(half_taps);
  std::vector<double> direction(half_taps);
  std::vector<double> product(half_taps);
  for (uint32_t index = 0; index < half_taps; ++index) {
    preconditioned[index] = residual[index] / diagonal[index];
    direction[index] = preconditioned[index];
  }
  double residual_product = DotProduct(residual, preconditioned);
  const double target_norm =
      std::sqrt(DotProduct(right_hand_side, right_hand_side)) *
      kRelativeTolerance;

  for (uint32_t iteration = 0; iteration < kMaximumIterations; ++iteration) {
    apply_normal_matrix(direction, &product);
    const double denominator = DotProduct(direction, product);
    if (!std::isfinite(denominator) || denominator <= 0.0) {
      SetError(L"The weighted least-squares solver became unstable.");
      return false;
    }
    const double step = residual_product / denominator;
    for (uint32_t index = 0; index < half_taps; ++index) {
      solution[index] += step * direction[index];
      residual[index] -= step * product[index];
    }
    if (std::sqrt(DotProduct(residual, residual)) <= target_norm) break;

    for (uint32_t index = 0; index < half_taps; ++index) {
      preconditioned[index] = residual[index] / diagonal[index];
    }
    const double next_residual_product =
        DotProduct(residual, preconditioned);
    if (!std::isfinite(next_residual_product) || residual_product == 0.0) {
      SetError(L"The weighted least-squares solver did not converge.");
      return false;
    }
    const double direction_scale = next_residual_product / residual_product;
    for (uint32_t index = 0; index < half_taps; ++index) {
      direction[index] =
          preconditioned[index] + direction_scale * direction[index];
    }
    residual_product = next_residual_product;
  }

  linear->assign(taps, 0.0);
  for (uint32_t index = 0; index < half_taps; ++index) {
    const double coefficient = solution[index];
    if (!std::isfinite(coefficient)) {
      SetError(L"The weighted least-squares filter contains invalid data.");
      return false;
    }
    (*linear)[index] = coefficient;
    (*linear)[taps - 1U - index] = coefficient;
  }
  return true;
}

bool DesignMinimumPhaseFilter(uint32_t sample_rate,
                              const QualitySpec& quality,
                              int32_t design,
                              std::vector<double>* phase_coefficients,
                              uint32_t* taps_per_phase) {
  const uint32_t output_rate = sample_rate * kUpsampleFactor;
  const uint32_t taps = sample_rate == 44100 ? quality.taps_44k
                                             : quality.taps_48k;
  std::vector<double> linear(taps);
  if (design == 1) {
    if (!DesignWeightedLeastSquaresPrototype(taps, &linear)) return false;
  } else {
    const double cutoff_hz = sample_rate == 44100 ? 22050.0 : 24000.0;
    const double normalized_cutoff = cutoff_hz / output_rate;
    const double center = (static_cast<double>(taps) - 1.0) * 0.5;
    const double window_scale = 1.0 / BesselI0(quality.kaiser_beta);
    for (uint32_t index = 0; index < taps; ++index) {
      const double distance = static_cast<double>(index) - center;
      const double sinc =
          std::abs(distance) < 1.0e-15
              ? 2.0 * normalized_cutoff
              : std::sin(2.0 * kPi * normalized_cutoff * distance) /
                    (kPi * distance);
      const double position = 2.0 * static_cast<double>(index) /
                                  static_cast<double>(taps - 1) -
                              1.0;
      const double window =
          BesselI0(quality.kaiser_beta *
                   std::sqrt(std::max(0.0, 1.0 - position * position))) *
          window_scale;
      linear[index] = sinc * window;
    }
  }
  double linear_sum = 0.0;
  for (double coefficient : linear) linear_sum += coefficient;
  if (std::abs(linear_sum) < 1.0e-18) {
    SetError(L"Unable to normalize the FIR prototype.");
    return false;
  }
  for (double& value : linear) value /= linear_sum;

  // Homomorphic spectral factorization: keep the causal cepstrum and double
  // positive quefrencies to preserve the magnitude while moving all possible
  // zeros inside the unit circle. A 32x FFT keeps truncation artifacts below
  // the 24-bit output floor even in the approximately 10K-tap Mastering mode.
  const size_t fft_size = NextPowerOfTwo(static_cast<size_t>(taps) * 32U);
  std::vector<std::complex<double>> spectrum(fft_size);
  for (uint32_t index = 0; index < taps; ++index) {
    spectrum[index] = std::complex<double>(linear[index], 0.0);
  }
  Fft(&spectrum, false);
  for (std::complex<double>& value : spectrum) {
    value = std::complex<double>(
        std::log(std::max(std::abs(value), 1.0e-14)), 0.0);
  }
  Fft(&spectrum, true);
  for (size_t index = 1; index < fft_size / 2; ++index) spectrum[index] *= 2.0;
  for (size_t index = fft_size / 2 + 1; index < fft_size; ++index) {
    spectrum[index] = std::complex<double>(0.0, 0.0);
  }
  Fft(&spectrum, false);
  for (std::complex<double>& value : spectrum) value = std::exp(value);
  Fft(&spectrum, true);

  std::vector<double> minimum_phase(taps);
  double minimum_sum = 0.0;
  for (uint32_t index = 0; index < taps; ++index) {
    minimum_phase[index] = spectrum[index].real();
    minimum_sum += minimum_phase[index];
  }
  if (std::abs(minimum_sum) < 1.0e-18) {
    SetError(L"Unable to normalize the minimum-phase FIR.");
    return false;
  }
  for (double& value : minimum_phase) value /= minimum_sum;

  const uint32_t phase_taps = taps / kUpsampleFactor;
  phase_coefficients->assign(taps, 0.0);
  for (uint32_t phase = 0; phase < kUpsampleFactor; ++phase) {
    for (uint32_t tap = 0; tap < phase_taps; ++tap) {
      // Reverse each phase so coefficients and the mirrored history are both
      // traversed forwards; this lets MSVC vectorize the four accumulators.
      (*phase_coefficients)[phase * phase_taps + phase_taps - 1U - tap] =
          minimum_phase[phase + kUpsampleFactor * tap];
    }
  }
  *taps_per_phase = phase_taps;
  return true;
}

uint32_t XorShift32(uint32_t* state) {
  uint32_t value = *state;
  value ^= value << 13;
  value ^= value >> 17;
  value ^= value << 5;
  *state = value;
  return value;
}

double Tpdf(uint32_t* state) {
  const int32_t first = static_cast<int32_t>(XorShift32(state) >> 17);
  const int32_t second = static_cast<int32_t>(XorShift32(state) >> 17);
  return static_cast<double>(first - second) * (1.0 / 32768.0);
}

class ChannelFilter {
 public:
  ChannelFilter(const std::vector<double>* coefficients,
                uint32_t taps_per_phase,
                double input_gain,
                const std::array<double, 5>& noise_coefficients,
                int32_t output_bits,
                bool noise_shaping,
                bool tpdf_dither,
                uint32_t seed)
      : coefficients_(coefficients),
        taps_per_phase_(taps_per_phase),
        input_gain_(input_gain),
        noise_coefficients_(noise_coefficients),
        output_min_(-(int32_t{1} << (output_bits - 1))),
        output_max_((int32_t{1} << (output_bits - 1)) - 1),
        noise_shaping_(noise_shaping),
        tpdf_dither_(tpdf_dither),
        history_(taps_per_phase * 2U, 0.0),
        dither_state_(seed) {}

  void Process(int32_t input, int32_t output[kUpsampleFactor]) {
    const double sample = static_cast<double>(input) * input_gain_;
    history_[write_index_] = sample;
    history_[write_index_ + taps_per_phase_] = sample;
    const double* history = history_.data() + write_index_ + 1U;

    for (uint32_t phase = 0; phase < kUpsampleFactor; ++phase) {
      const double* coefficients =
          coefficients_->data() + phase * taps_per_phase_;
      double sum0 = 0.0;
      double sum1 = 0.0;
      double sum2 = 0.0;
      double sum3 = 0.0;
      for (uint32_t tap = 0; tap < taps_per_phase_; tap += 4U) {
        sum0 += coefficients[tap] * history[tap];
        sum1 += coefficients[tap + 1U] * history[tap + 1U];
        sum2 += coefficients[tap + 2U] * history[tap + 2U];
        sum3 += coefficients[tap + 3U] * history[tap + 3U];
      }
      output[phase] = Quantize((sum0 + sum1) + (sum2 + sum3));
    }
    write_index_ = write_index_ + 1U == taps_per_phase_ ? 0U
                                                        : write_index_ + 1U;
  }

 private:
  int32_t Quantize(double value) {
    double shaped = value;
    if (noise_shaping_) {
      for (size_t tap = 0; tap < noise_error_.size(); ++tap) {
        shaped += noise_coefficients_[tap] * noise_error_[tap];
      }
    }
    const double quantizer_input =
        shaped + (tpdf_dither_ ? Tpdf(&dither_state_) : 0.0);
    if (quantizer_input >= static_cast<double>(output_max_)) {
      noise_error_.fill(0.0);
      return output_max_;
    }
    if (quantizer_input <= static_cast<double>(output_min_)) {
      noise_error_.fill(0.0);
      return output_min_;
    }
    const int32_t rounded = quantizer_input >= 0.0f
                                ? static_cast<int32_t>(quantizer_input + 0.5f)
                                : static_cast<int32_t>(quantizer_input - 0.5f);
    if (noise_shaping_) {
      for (size_t tap = noise_error_.size() - 1; tap > 0; --tap) {
        noise_error_[tap] = noise_error_[tap - 1];
      }
      noise_error_[0] = static_cast<double>(rounded) - shaped;
    }
    return rounded;
  }

  const std::vector<double>* coefficients_;
  uint32_t taps_per_phase_;
  double input_gain_;
  std::array<double, 5> noise_coefficients_;
  int32_t output_min_;
  int32_t output_max_;
  bool noise_shaping_;
  bool tpdf_dither_;
  std::vector<double> history_;
  std::array<double, 5> noise_error_{};
  uint32_t write_index_ = 0;
  uint32_t dither_state_;
};

void WriteLe16(std::ostream& output, uint16_t value) {
  const uint8_t bytes[] = {static_cast<uint8_t>(value),
                           static_cast<uint8_t>(value >> 8)};
  output.write(reinterpret_cast<const char*>(bytes), sizeof(bytes));
}

void WriteLe32(std::ostream& output, uint32_t value) {
  const uint8_t bytes[] = {
      static_cast<uint8_t>(value), static_cast<uint8_t>(value >> 8),
      static_cast<uint8_t>(value >> 16), static_cast<uint8_t>(value >> 24)};
  output.write(reinterpret_cast<const char*>(bytes), sizeof(bytes));
}

bool WriteWavHeader(std::ofstream& output,
                    const WavInfo& source,
                    uint16_t output_bits,
                    uint32_t output_data_bytes) {
  output.write("RIFF", 4);
  WriteLe32(output, output_data_bytes + 36U);
  output.write("WAVEfmt ", 8);
  WriteLe32(output, 16U);
  WriteLe16(output, 1U);
  WriteLe16(output, source.channels);
  const uint32_t output_rate = source.sample_rate * kUpsampleFactor;
  const uint16_t output_block_align =
      source.channels * static_cast<uint16_t>(output_bits / 8U);
  WriteLe32(output, output_rate);
  WriteLe32(output, output_rate * output_block_align);
  WriteLe16(output, output_block_align);
  WriteLe16(output, output_bits);
  output.write("data", 4);
  WriteLe32(output, output_data_bytes);
  return output.good();
}

int32_t ReadPcmSample(const uint8_t* source, uint16_t bits_per_sample) {
  if (bits_per_sample == 16U) {
    return static_cast<int16_t>(ReadLe16(source));
  }
  int32_t value = static_cast<int32_t>(source[0]) |
                  (static_cast<int32_t>(source[1]) << 8) |
                  (static_cast<int32_t>(source[2]) << 16);
  if ((value & 0x00800000) != 0) value |= static_cast<int32_t>(0xFF000000);
  return value;
}

void DecodePcmBlock(const std::vector<uint8_t>& bytes,
                    uint16_t bits_per_sample,
                    std::vector<int32_t>* samples) {
  const uint32_t bytes_per_sample = bits_per_sample / 8U;
  samples->resize(bytes.size() / bytes_per_sample);
  for (size_t index = 0; index < samples->size(); ++index) {
    (*samples)[index] =
        ReadPcmSample(bytes.data() + index * bytes_per_sample,
                      bits_per_sample);
  }
}

void EncodePcmBlock(const std::vector<int32_t>& samples,
                    uint16_t bits_per_sample,
                    std::vector<uint8_t>* bytes) {
  const uint32_t bytes_per_sample = bits_per_sample / 8U;
  bytes->resize(samples.size() * bytes_per_sample);
  for (size_t index = 0; index < samples.size(); ++index) {
    const uint32_t value = static_cast<uint32_t>(samples[index]);
    uint8_t* destination = bytes->data() + index * bytes_per_sample;
    destination[0] = static_cast<uint8_t>(value);
    destination[1] = static_cast<uint8_t>(value >> 8);
    if (bits_per_sample == 24U) {
      destination[2] = static_cast<uint8_t>(value >> 16);
    }
  }
}

bool ProcessFrames(const std::vector<int32_t>& interleaved_input,
                   uint32_t input_frames,
                   uint16_t channels,
                   std::vector<ChannelFilter>* filters,
                   std::vector<int32_t>* interleaved_output) {
  const uint32_t output_frames = input_frames * kUpsampleFactor;
  std::vector<std::vector<int32_t>> channel_output(
      channels, std::vector<int32_t>(output_frames));

  const auto process_channel = [&](uint16_t channel) {
    int32_t phases[kUpsampleFactor] = {};
    for (uint32_t frame = 0; frame < input_frames; ++frame) {
      const int32_t sample = interleaved_input.empty()
                                 ? 0
                                 : interleaved_input[frame * channels + channel];
      (*filters)[channel].Process(sample, phases);
      for (uint32_t phase = 0; phase < kUpsampleFactor; ++phase) {
        channel_output[channel][frame * kUpsampleFactor + phase] =
            phases[phase];
      }
    }
  };

  std::vector<std::thread> workers;
  for (uint16_t channel = 1; channel < channels; ++channel) {
    workers.emplace_back(process_channel, channel);
  }
  process_channel(0);
  for (std::thread& worker : workers) worker.join();

  interleaved_output->resize(
      static_cast<size_t>(output_frames) * channels);
  for (uint32_t frame = 0; frame < output_frames; ++frame) {
    for (uint16_t channel = 0; channel < channels; ++channel) {
      (*interleaved_output)[frame * channels + channel] =
          channel_output[channel][frame];
    }
  }
  return true;
}

}  // namespace

extern "C" {

int32_t gac_convert_wav(const wchar_t* input_path,
                        const wchar_t* output_path,
                        int32_t design,
                        int32_t quality,
                        double headroom_db,
                        int32_t output_bits,
                        int32_t noise_shaping,
                        int32_t tpdf_dither) {
  g_progress.store(0.0);
  g_cancel_requested.store(false);
  SetError(L"");
  if (input_path == nullptr || output_path == nullptr ||
      input_path[0] == L'\0' || output_path[0] == L'\0') {
    SetError(L"Both input and output paths are required.");
    return 1;
  }
  if (_wcsicmp(input_path, output_path) == 0) {
    SetError(L"The output path must be different from the source file.");
    return 1;
  }
  design = std::clamp<int32_t>(design, 0, 1);
  quality = std::clamp<int32_t>(quality, 0, 2);
  headroom_db = std::clamp(headroom_db, -12.0, 3.0);
  if (output_bits != 16 && output_bits != 24) {
    SetError(L"Output bit depth must be 16 or 24 bits.");
    return 1;
  }

  std::ifstream input(input_path, std::ios::binary);
  if (!input.is_open()) {
    SetError(L"Unable to open the source WAV file.");
    return 2;
  }
  WavInfo info;
  if (!ParseWav(input, &info)) return 3;
  g_progress.store(0.02);

  std::vector<double> phase_coefficients;
  uint32_t taps_per_phase = 0;
  if (!DesignMinimumPhaseFilter(info.sample_rate, kQualitySpecs[quality],
                                design, &phase_coefficients,
                                &taps_per_phase)) {
    return 4;
  }
  g_progress.store(0.08);

  const uint64_t source_frames = info.data_bytes / info.block_align;
  const uint64_t tail_frames = taps_per_phase - 1U;
  const uint64_t total_input_frames = source_frames + tail_frames;
  const uint64_t output_frames = total_input_frames * kUpsampleFactor;
  const uint16_t output_block_align = static_cast<uint16_t>(
      info.channels * static_cast<uint16_t>(output_bits / 8));
  const uint64_t output_data_bytes = output_frames * output_block_align;
  if (output_data_bytes > std::numeric_limits<uint32_t>::max() - 36ULL) {
    SetError(L"The 4x output exceeds the 4 GB RIFF/WAV size limit.");
    return 5;
  }

  std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
  if (!output.is_open()) {
    SetError(L"Unable to create the output WAV file in the selected folder.");
    return 6;
  }
  if (!WriteWavHeader(output, info, static_cast<uint16_t>(output_bits),
                      static_cast<uint32_t>(output_data_bytes))) {
    output.close();
    _wremove(output_path);
    SetError(L"Unable to write the WAV header.");
    return 7;
  }

  const double bit_depth_scale =
      std::ldexp(1.0, output_bits - info.bits_per_sample);
  const double input_gain = kUpsampleFactor *
                            std::pow(10.0, headroom_db / 20.0) *
                            bit_depth_scale;
  const std::array<double, 5> noise_coefficients =
      info.sample_rate == 44100
          ? std::array<double, 5>{-4.45219631032, 8.41508536432,
                                  -8.41508536432, 4.45219631032, -1.0}
          : std::array<double, 5>{-4.53550663875, 8.64850715592,
                                  -8.64850715592, 4.53550663875, -1.0};
  std::vector<ChannelFilter> filters;
  filters.reserve(info.channels);
  for (uint16_t channel = 0; channel < info.channels; ++channel) {
    filters.emplace_back(&phase_coefficients, taps_per_phase, input_gain,
                         noise_coefficients, output_bits,
                         noise_shaping != 0, tpdf_dither != 0,
                         0x9E3779B9U ^ (0x243F6A88U * (channel + 1U)));
  }

  uint64_t processed_frames = 0;
  uint64_t remaining_source_frames = source_frames;
  std::vector<uint8_t> input_bytes;
  std::vector<int32_t> input_samples;
  std::vector<int32_t> output_samples;
  std::vector<uint8_t> output_bytes;

  while (remaining_source_frames > 0 && !g_cancel_requested.load()) {
    const uint32_t block_frames = static_cast<uint32_t>(
        std::min<uint64_t>(remaining_source_frames, kFramesPerBlock));
    input_bytes.resize(static_cast<size_t>(block_frames) * info.block_align);
    const std::streamsize block_bytes = static_cast<std::streamsize>(
        input_bytes.size());
    if (!ReadExact(input, input_bytes.data(), block_bytes)) {
      output.close();
      _wremove(output_path);
      SetError(L"The WAV audio data ended unexpectedly.");
      return 8;
    }
    DecodePcmBlock(input_bytes, info.bits_per_sample, &input_samples);
    ProcessFrames(input_samples, block_frames, info.channels, &filters,
                  &output_samples);
    EncodePcmBlock(output_samples, static_cast<uint16_t>(output_bits),
                   &output_bytes);
    output.write(reinterpret_cast<const char*>(output_bytes.data()),
                 static_cast<std::streamsize>(output_bytes.size()));
    if (!output.good()) {
      output.close();
      _wremove(output_path);
      SetError(L"The output drive could not accept more audio data.");
      return 9;
    }
    remaining_source_frames -= block_frames;
    processed_frames += block_frames;
    g_progress.store(0.08 + 0.90 * static_cast<double>(processed_frames) /
                                static_cast<double>(total_input_frames));
  }

  uint64_t remaining_tail_frames = tail_frames;
  input_samples.clear();
  while (remaining_tail_frames > 0 && !g_cancel_requested.load()) {
    const uint32_t block_frames = static_cast<uint32_t>(
        std::min<uint64_t>(remaining_tail_frames, kFramesPerBlock));
    ProcessFrames(input_samples, block_frames, info.channels, &filters,
                  &output_samples);
    EncodePcmBlock(output_samples, static_cast<uint16_t>(output_bits),
                   &output_bytes);
    output.write(reinterpret_cast<const char*>(output_bytes.data()),
                 static_cast<std::streamsize>(output_bytes.size()));
    if (!output.good()) {
      output.close();
      _wremove(output_path);
      SetError(L"The output drive could not accept the FIR tail.");
      return 10;
    }
    remaining_tail_frames -= block_frames;
    processed_frames += block_frames;
    g_progress.store(0.08 + 0.90 * static_cast<double>(processed_frames) /
                                static_cast<double>(total_input_frames));
  }

  output.close();
  if (g_cancel_requested.load()) {
    _wremove(output_path);
    SetError(L"Conversion cancelled.");
    g_progress.store(0.0);
    return 11;
  }
  if (!output.good()) {
    _wremove(output_path);
    SetError(L"Unable to finalize the output WAV file.");
    return 12;
  }
  g_progress.store(1.0);
  return 0;
}

double gac_get_progress() { return g_progress.load(); }

void gac_request_cancel() { g_cancel_requested.store(true); }

int32_t gac_copy_last_error(wchar_t* destination, int32_t capacity) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  const int32_t required = static_cast<int32_t>(g_last_error.size() + 1U);
  if (destination == nullptr || capacity <= 0) return required;
  const size_t count = std::min<size_t>(g_last_error.size(), capacity - 1U);
  std::wmemcpy(destination, g_last_error.data(), count);
  destination[count] = L'\0';
  return required;
}

}  // extern "C"
