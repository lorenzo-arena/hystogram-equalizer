#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>

extern "C" {
    #define STB_IMAGE_IMPLEMENTATION
    #include "stb_image.h"
    #define STB_IMAGE_WRITE_IMPLEMENTATION
    #include "stb_image_write.h"

    #include "log.h"
    #include "stopwatch.h"
    #include "arguments.h"
    #include "cexception/lib/CException.h"
    #include "errors.h"
}

#include "hsl.cuh"
#include "equalizer.cuh"
#include "error_checker.cuh"

struct arguments arguments;

const char *argp_program_version =
" 1.0";

const char doc[] =
"histogram-equalizer-cudaa -- Used to equalize the histogram of an image.";

int main(int argc, char **argv)
{
    int width, height, bpp;
    uint8_t *rgb_image = NULL;
    uint8_t *output_image = NULL;
    stopwatch_t processing_sw;
    stopwatch_t total_sw;
    CEXCEPTION_T e;
    uint8_t *tmp;
 
    Try {
        // This calls are useful to improve the runtime load time
        gpuErrorCheck( cudaMalloc(&tmp, 0) );
        gpuErrorCheck( cudaFree(tmp) );

        set_default_arguments(&arguments);

        argp_parse(&argp, argc, argv, 0, 0, &arguments);

        if(arguments.stopwatch)
        {
            stopwatch_start(&total_sw);
        }

        rgb_image = stbi_load(arguments.args[0], &width, &height, &bpp, STBI_rgb_alpha);

        if(NULL == rgb_image)
        {
            log_error("Couldn't read image %s", arguments.args[0]);
            Throw(UNALLOCATED_MEMORY);
        }

        // Image BPP will be 4 but the reading is forced to be RGB only
        log_info("BPP %d", bpp);
        log_info("Width %d", width);
        log_info("Height %d", height);

        if(arguments.stopwatch)
        {
            stopwatch_start(&processing_sw);
        }

        int res = equalize((rgb_pixel_t *)rgb_image, width, height, &output_image);

        if(cudaSuccess != res)
        {
            log_error("Error while equalizing image!");
            Throw(res);
        }

        if(NULL == output_image)
        {
            log_error("Error while equalizing image!");
            Throw(UNALLOCATED_MEMORY);
        }

        if(arguments.stopwatch)
        {
            stopwatch_stop(&processing_sw);

            struct timespec elapsed = stopwatch_get_elapsed(&processing_sw);

            log_info("Elapsed time: %ld.%09ld",
                elapsed.tv_sec,
                elapsed.tv_nsec);
        }

        log_info("Writing result in %s..", arguments.args[1]);
        stbi_write_jpg(arguments.args[1], width, height, STBI_rgb_alpha, output_image, 100);

        if(arguments.stopwatch)
        {
            stopwatch_stop(&total_sw);

            struct timespec elapsed = stopwatch_get_elapsed(&total_sw);

            log_info("Total elapsed time: %ld.%09ld",
                elapsed.tv_sec,
                elapsed.tv_nsec);
        }
    } Catch(e) {
        log_error("Catched error %d!", e);
    }

    // Clean up buffers
    if(NULL != rgb_image)
    {
        stbi_image_free(rgb_image);
    }

    if(NULL != output_image)
    {
        free(output_image);
    }

    return 0;
}
