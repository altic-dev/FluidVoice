/*
    Copyright 2018-2025 Picovoice Inc.

    You may not use this file except in compliance with the license. A copy of the license is located in the "LICENSE"
    file accompanying this source.

    Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
    an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
    specific language governing permissions and limitations under the License.
*/

#ifndef PICOVOICE_H
#define PICOVOICE_H

#include <stdint.h>

#ifdef __cplusplus

extern "C" {

#endif

#ifdef _MSC_VER

#define PV_API __declspec(dllexport)

#else

#define PV_API __attribute__((visibility("default")))

#endif

/**
 * Audio sample rate accepted by Picovoice.
 */
PV_API int32_t pv_sample_rate(void);

/**
 * Status codes.
 */
typedef enum {
    PV_STATUS_SUCCESS = 0,
    PV_STATUS_OUT_OF_MEMORY,
    PV_STATUS_IO_ERROR,
    PV_STATUS_INVALID_ARGUMENT,
    PV_STATUS_STOP_ITERATION,
    PV_STATUS_KEY_ERROR,
    PV_STATUS_INVALID_STATE,
    PV_STATUS_RUNTIME_ERROR,
    PV_STATUS_ACTIVATION_ERROR,
    PV_STATUS_ACTIVATION_LIMIT_REACHED,
    PV_STATUS_ACTIVATION_THROTTLED,
    PV_STATUS_ACTIVATION_REFUSED
} pv_status_t;

/**
 * Provides string representations of status codes.
 *
 * @param status Status code.
 * @return String representation.
 */
PV_API const char *pv_status_to_string(pv_status_t status);

/**
 * If a function returns a failure (any pv_status_t other than PV_STATUS_SUCCESS), this function can be called
 * to get a series of error messages related to the failure. This function can only be called only once per
 * failure status on another function. The memory for `message_stack` must be freed using `pv_free_error_stack`.
 *
 * Regardless of the return status of this function, if `message_stack` is not `NULL`, then `message_stack`
 * contains valid memory. However, a failure status on this function indicates that future error messages
 * may not be reported.
 *
 * @param[out] message_stack Array of messages relating to the failure. Messages are NULL terminated strings.
 *                           The array and messages must be freed using `pv_free_error_stack`.
 * @param[out] message_stack_depth The number of messages in the `message_stack` array.
 */
PV_API pv_status_t pv_get_error_stack(
        char ***message_stack,
        int32_t *message_stack_depth);

/**
 * This function frees the memory used by error messages allocated by `pv_get_error_stack`.
 *
 * @param message_stack Array of messages relating to the failure, allocated from `pv_get_error_stack`.
 */
PV_API void pv_free_error_stack(char **message_stack);

#ifdef __cplusplus

}

#endif

#endif // PICOVOICE_H
