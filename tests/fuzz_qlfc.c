/* libFuzzer harness for the QLFC entropy decoder.
 *
 * This is the deepest attack surface: the coder reads a decoded size and a
 * stream of arithmetic-coded runs from the compressed payload, with no CRC in
 * between. The harness gives it a malloc-free static output buffer so
 * AddressSanitizer redzones catch any write past it, and sets the input end so
 * reads stop at the payload.
 *
 * Unlike the API-level harness, the coder is compiled into this binary with
 * coverage instrumentation, so libFuzzer gets real feedback from the decoder.
 * Seeds are payloads extracted from real streams (scripts/extract_qlfc_seed.py).
 *
 * Build (clang):  see .github/fuzz.sh
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define OUTPUT_CAP (1 << 20)

int bsc_coder_init(int features);
int bsc_coder_decompress_bounded(const unsigned char *input, int inputSize,
                                 unsigned char *output, int outputSize,
                                 int coder, int features);
void bsc_qlfc_set_output_limit(int limit);
void bsc_qlfc_set_input_end(const unsigned char *end);

/* Redzones after the array catch a vectorised tail store that runs past the
   limit. The logical bound is still OUTPUT_CAP. */
static unsigned char output[OUTPUT_CAP + 4096];

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void)argc; (void)argv;
    bsc_coder_init(0);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 4 || size > (1u << 20))
        return 0;

    bsc_coder_decompress_bounded(data, (int)size, output, OUTPUT_CAP,
                                 1 /* BSC_CODER_STATIC */, 0);
    return 0;
}
