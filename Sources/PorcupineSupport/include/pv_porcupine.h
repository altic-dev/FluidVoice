/*
    Copyright 2018-2025 Picovoice Inc.

    You may not use this file except in compliance with the license. A copy of the license is located in the "LICENSE"
    file accompanying this source.

    Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
    an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
    specific language governing permissions and limitations under the License.
*/

#ifndef PV_PORCUPINE_H
#define PV_PORCUPINE_H

#include <stdbool.h>
#include <stdint.h>

#include "picovoice.h"

#ifdef __cplusplus

extern "C" {

#endif

/**
 * Forward declaration for Porcupine wake word engine. It detects utterances of given keywords within an incoming stream
 * of audio in real-time. It processes incoming audio in consecutive frames and for each frame emits the detection
 * result. The number of samples per frame can be attained by calling 'pv_porcupine_frame_length()'. The incoming audio
 * needs to have a sample rate equal to 'pv_sample_rate()' and be 16-bit linearly-encoded. Porcupine operates on
 * single-channel audio.
 */
typedef struct pv_porcupine pv_porcupine_t;

/**
 * Constructor.
 *
 * @param access_key AccessKey obtained from Picovoice Console (https://console.picovoice.ai/).
 * @param model_path Absolute path to the file containing model parameters.
 * @param device String representation of the device (e.g., CPU or GPU) to use. If set to `best`, the most
 * suitable device is selected automatically. If set to `gpu`, the engine uses the first available GPU device. To select a specific
 * GPU device, set this argument to `gpu:${GPU_INDEX}`, where `${GPU_INDEX}` is the index of the target GPU. If set to
 * `cpu`, the engine will run on the CPU with the default number of threads. To specify the number of threads, set this
 * argument to `cpu:${NUM_THREADS}`, where `${NUM_THREADS}` is the desired number of threads.
 * @param num_keywords Number of keywords to monitor.
 * @param keyword_paths Absolute paths to keyword model files.
 * @param sensitivities Sensitivities for detecting keywords. Each value should be a number within [0, 1]. A higher
 * sensitivity results in fewer misses at the cost of increasing the false alarm rate.
 * @param[out] object Constructed instance of Porcupine.
 * @return Status code. Returns 'PV_STATUS_INVALID_ARGUMENT', 'PV_STATUS_IO_ERROR', or 'PV_STATUS_OUT_OF_MEMORY' on
 * failure.
 */
PV_API pv_status_t pv_porcupine_init(
        const char *access_key,
        const char *model_path,
        const char *device,
        int32_t num_keywords,
        const char *const *keyword_paths,
        const float *sensitivities,
        pv_porcupine_t **object);

/**
 * Destructor.
 *
 * @param object Porcupine object.
 */
PV_API void pv_porcupine_delete(pv_porcupine_t *object);

/**
 * Processes a frame of the incoming audio stream and emits the detection result.
 *
 * @param object Porcupine object.
 * @param pcm A frame of audio samples. The number of samples per frame can be attained by calling
 * 'pv_porcupine_frame_length()'. The incoming audio needs to have a sample rate equal to 'pv_sample_rate()' and be
 * 16-bit linearly-encoded. Porcupine operates on single-channel audio.
 * @param[out] keyword_index Index of observed keyword at the end of the current frame. Indexing is 0-based and matches
 * the ordering of keyword models provided to 'pv_porcupine_init()'. If no keyword is detected then it is set to -1.
 * @return Status code. Returns 'PV_STATUS_INVALID_ARGUMENT' or 'PV_STATUS_OUT_OF_MEMORY' on failure.
 */
PV_API pv_status_t pv_porcupine_process(pv_porcupine_t *object, const int16_t *pcm, int32_t *keyword_index);

/**
 * Getter for version.
 *
 * @return Version.
 */
PV_API const char *pv_porcupine_version(void);

/**
 * Getter for number of audio samples per frame.
 *
 * @return Frame length.
 */
PV_API int32_t pv_porcupine_frame_length(void);

/**
 * Gets a list of hardware devices that can be specified when calling `pv_porcupine_init`
 *
 * @param[out] hardware_devices Array of available hardware devices. Devices are NULL terminated strings.
 *                              The array must be freed using `pv_porcupine_free_hardware_devices`.
 * @param[out] num_hardware_devices The number of devices in the `hardware_devices` array.
 * @return Status code. Returns `PV_STATUS_OUT_OF_MEMORY`, `PV_STATUS_INVALID_ARGUMENT`, `PV_STATUS_INVALID_STATE`,
 * `PV_STATUS_RUNTIME_ERROR`, `PV_STATUS_ACTIVATION_ERROR`, `PV_STATUS_ACTIVATION_LIMIT_REACHED`,
 * `PV_STATUS_ACTIVATION_THROTTLED`, or `PV_STATUS_ACTIVATION_REFUSED` on failure.
 */
PV_API pv_status_t pv_porcupine_list_hardware_devices(
        char ***hardware_devices,
        int32_t *num_hardware_devices);

/**
 * Frees memory allocated by `pv_porcupine_list_hardware_devices`.
 *
 * @param[out] hardware_devices Array of available hardware devices allocated by `pv_porcupine_list_hardware_devices`.
 * @param[out] num_hardware_devices The number of devices in the `hardware_devices` array.
 */
PV_API void pv_porcupine_free_hardware_devices(
        char **hardware_devices,
        int32_t num_hardware_devices);

#ifdef __cplusplus
}

#endif

#endif // PV_PORCUPINE_H
