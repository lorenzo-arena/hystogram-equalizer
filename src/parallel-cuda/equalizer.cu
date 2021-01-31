#include "equalizer.cuh"

#include "error_checker.cuh"

extern "C" {
    #include <stdio.h>
    #include "cexception/lib/CException.h"
    #include "log.h"
    #include "errors.h"
    #include "arguments.h"
    #include "defines.h"
}

#define BLOCK_SIZE (512)

__global__ void compute_histogram(const float *image,
                                  unsigned int *bins,
                                  unsigned int num_elements)
{
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

    extern __shared__ unsigned int bins_s[];
    for (unsigned int binIdx = threadIdx.x; binIdx < N_BINS; binIdx += blockDim.x)
    {
        bins_s[binIdx] = 0;
    }

    __syncthreads();

    for (unsigned int i = tid; i < num_elements; i += blockDim.x * gridDim.x)
    {
        atomicAdd(&(bins_s[(unsigned int)__float2int_rn(image[i] * (N_BINS - 1))]), 1);
    }

    __syncthreads();

    for (unsigned int binIdx = threadIdx.x; binIdx < N_BINS; binIdx += blockDim.x)
    {
        atomicAdd(&(bins[binIdx]), bins_s[binIdx]);
    }
}

__global__ void convert_rgb_to_hsl(const rgb_pixel_t *rgb_image,
                                   hsl_image_t hsl_image,
                                   unsigned int num_elements,
                                   unsigned int offset)
{
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if(tid < num_elements)
    {
        const rgb_pixel_t rgb_pixel = *(rgb_pixel_t *)(&rgb_image[offset + tid]);

        hsl_pixel_t hsl_pixel = { .h = 0, .s = 0, .l = 0 };

        rgb_to_hsl(rgb_pixel, &hsl_pixel);

        hsl_image.h[offset + tid] = hsl_pixel.h;
        hsl_image.s[offset + tid] = hsl_pixel.s;
        hsl_image.l[offset + tid] = hsl_pixel.l;
    }
}

__global__ void convert_hsl_to_rgb(const hsl_image_t hsl_image,
                                   rgb_pixel_t *rgb_image,
                                   unsigned int num_elements,
                                   unsigned int offset)
{
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if(tid < num_elements)
    {
        rgb_pixel_t *pixel_offset = &rgb_image[offset + tid];

        rgb_pixel_t rgb_pixel = { .r = 0, .g = 0, .b = 0, .a = 0xFF };

        hsl_pixel_t hsl_pixel = {
            .h = hsl_image.h[offset + tid],
            .s = hsl_image.s[offset + tid],
            .l = hsl_image.l[offset + tid]
        };

        hsl_to_rgb(hsl_pixel, &rgb_pixel);

        pixel_offset->r = rgb_pixel.r;
        pixel_offset->g = rgb_pixel.g;
        pixel_offset->b = rgb_pixel.b;
        pixel_offset->a = rgb_pixel.a;
    }
}

__global__ void compute_cdf(unsigned int *input, unsigned int *output, int input_size)
{
    __shared__ unsigned int sh_out[BLOCK_SIZE];
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < input_size)
    {
        sh_out[threadIdx.x] = input[tid];
    }

    for (unsigned int stride = 1; stride < blockDim.x; stride *= 2)
    {
        __syncthreads();

        if(threadIdx.x >= stride)
        {
            sh_out[threadIdx.x] += sh_out[threadIdx.x - stride];
        }
    }

    __syncthreads();

    if (tid < input_size)
    {
        output[tid] = sh_out[threadIdx.x];
    }
}

__global__ void compute_normalized_cdf(unsigned int *cdf, float *cdf_norm, int cdf_size, int norm_factor)
{
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if(tid < cdf_size)
    {
        cdf_norm[tid] = ((float)(cdf[tid] - cdf[0]) / (norm_factor - cdf[0])) * (cdf_size - 1);
    }
}

__global__ void apply_normalized_cdf(const float *cdf_norm, const hsl_image_t hsl_image, int cdf_size, int image_size)
{
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if(tid < image_size)
    {
        hsl_image.l[tid] = cdf_norm[(unsigned int)__float2int_rn(hsl_image.l[tid] * (cdf_size - 1))] / (cdf_size - 1);
    }
}

int equalize(rgb_pixel_t *input, unsigned int width, unsigned int height, uint8_t **output)
{
    CEXCEPTION_T e = NO_ERROR;

    int blocksPerGrid = 0;
    const int nStreams = 100;
    cudaStream_t streams[nStreams];
    const int streamSize = ((width * height) + nStreams - 1) / nStreams;

    rgb_pixel_t *d_rgb_image = NULL;
    rgb_pixel_t *h_rgb_image = NULL;
    unsigned int *d_histogram = NULL;
    unsigned int *d_cdf = NULL;
    float *d_cdf_norm = NULL;

    hsl_image_t d_hsl_image = {
        .h = NULL,
        .s = NULL,
        .l = NULL
    };

    Try {
        for (int i = 0; i < nStreams; i++)
        {
            gpuErrorCheck( cudaStreamCreate(&streams[i]) );
        }

        gpuErrorCheck( cudaMallocHost((void**)&h_rgb_image, width * height * sizeof(rgb_pixel_t)) );
        gpuErrorCheck( cudaMalloc((void**)&d_rgb_image, width * height * sizeof(rgb_pixel_t)) );
        memcpy(h_rgb_image, input, width * height * sizeof(rgb_pixel_t));

        gpuErrorCheck( cudaMalloc((void**)&(d_hsl_image.h), width * height * sizeof(int)) );
        gpuErrorCheck( cudaMalloc((void**)&(d_hsl_image.s), width * height * sizeof(float)) );
        gpuErrorCheck( cudaMalloc((void**)&(d_hsl_image.l), width * height * sizeof(float)) );

        // Allocate memory for the output
        *output = (uint8_t *)calloc(width * height, sizeof(rgb_pixel_t));

        check_pointer(*output);

        gpuErrorCheck( cudaMalloc((void**)&d_histogram, N_BINS * sizeof(unsigned int)) );
        gpuErrorCheck( cudaMalloc((void**)&d_cdf, N_BINS * sizeof(unsigned int)) );
        gpuErrorCheck( cudaMalloc((void**)&d_cdf_norm, N_BINS * sizeof(float)) );

        // **************************************
        // STEP 1 - convert every pixel from RGB to HSL
        for (int i = 0; i < nStreams; i++)
        {
            int offset = i * streamSize;
            int size = streamSize;

            if(i == (nStreams - 1))
            {
                size = (width * height) - (offset);
            }

            gpuErrorCheck( cudaMemcpyAsync(&d_rgb_image[offset], &h_rgb_image[offset], 
                                            size * sizeof(rgb_pixel_t), cudaMemcpyHostToDevice, 
                                            streams[i]) );

            blocksPerGrid = ((size) + BLOCK_SIZE - 1) / BLOCK_SIZE;
            convert_rgb_to_hsl<<<blocksPerGrid, BLOCK_SIZE, 0, streams[i]>>>(d_rgb_image, d_hsl_image, size, offset);
        }

        for (int i = 0; i < nStreams; i++)
        {
            cudaStreamSynchronize(streams[i]);
        }

        // **************************************
        // STEP 2 - compute the histogram of the luminance for each pixel
        blocksPerGrid = 30;
        compute_histogram<<<blocksPerGrid, BLOCK_SIZE, N_BINS * sizeof(unsigned int)>>>(d_hsl_image.l, d_histogram, (width * height));

        // **************************************
        // STEP 3 - compute the cumulative distribution function by applying the parallelized
        // version of the scan algorithm
        blocksPerGrid = (N_BINS + BLOCK_SIZE - 1) / BLOCK_SIZE;
        compute_cdf<<<blocksPerGrid, BLOCK_SIZE>>>(d_histogram, d_cdf, N_BINS);

        // **************************************
        // STEP 4 - compute the normalized cumulative distribution function
        blocksPerGrid = (N_BINS + BLOCK_SIZE - 1) / BLOCK_SIZE;
        compute_normalized_cdf<<<blocksPerGrid, BLOCK_SIZE>>>(d_cdf, d_cdf_norm, N_BINS, (width * height));

        // **************************************
        // STEP 5 - apply the normalized CDF to the luminance for each pixel
        blocksPerGrid = ((width * height) + BLOCK_SIZE - 1) / BLOCK_SIZE;
        apply_normalized_cdf<<<blocksPerGrid, BLOCK_SIZE>>>(d_cdf_norm, d_hsl_image, N_BINS, (width * height));

        // **************************************
        // STEP 6 - convert each HSL pixel back to RGB
        for (int i = 0; i < nStreams; i++)
        {
            int offset = i * streamSize;
            int size = streamSize;

            if(i == (nStreams - 1))
            {
                size = (width * height) - (offset);
            }

            blocksPerGrid = ((size) + BLOCK_SIZE - 1) / BLOCK_SIZE;
            convert_hsl_to_rgb<<<blocksPerGrid, BLOCK_SIZE, 0, streams[i]>>>(d_hsl_image, d_rgb_image, size, offset);

            gpuErrorCheck( cudaMemcpyAsync(&h_rgb_image[offset], &d_rgb_image[offset], 
                                           size * sizeof(rgb_pixel_t), cudaMemcpyDeviceToHost, 
                                           streams[i]) );
        }

        for (int i = 0; i < nStreams; i++)
        {
            cudaStreamSynchronize(streams[i]);
        }

        // Copy the result back from the device
        memcpy(*output, h_rgb_image, width * height * sizeof(rgb_pixel_t));

        if(arguments.log_histogram)
        {
            unsigned int *h_histogram = NULL;
            unsigned int *h_cdf = NULL;
            float *h_cdf_norm = NULL;

            h_histogram = (unsigned int *)calloc(N_BINS, sizeof(unsigned int));
            h_cdf = (unsigned int *)calloc(N_BINS, sizeof(unsigned int));
            h_cdf_norm = (float *)calloc(N_BINS, sizeof(float));

            check_pointer(h_histogram);
            check_pointer(h_cdf);
            check_pointer(h_cdf_norm);

            gpuErrorCheck( cudaMemcpy(h_histogram, d_histogram, N_BINS * sizeof(unsigned int), cudaMemcpyDeviceToHost) );
            gpuErrorCheck( cudaMemcpy(h_cdf, d_cdf, N_BINS * sizeof(unsigned int), cudaMemcpyDeviceToHost) );
            gpuErrorCheck( cudaMemcpy(h_cdf_norm, d_cdf_norm, N_BINS * sizeof(float), cudaMemcpyDeviceToHost) );

            log_info("Printing histogram..");
            for(int bin = 0; bin < N_BINS; bin++)
            {
                log_info("%d:%d", bin, h_histogram[bin]);
            }

            log_info("Printing cdf..");
            for(int bin = 0; bin < N_BINS; bin++)
            {
                log_info("%d:%d", bin, h_cdf[bin]);
            }

            log_info("Printing normalized cdf..");
            for(int bin = 0; bin < N_BINS; bin++)
            {
                log_info("%d:%g", bin, h_cdf_norm[bin]);
            }

            free(h_histogram);
            free(h_cdf);
            free(h_cdf_norm);
        }
    } Catch(e) {
        log_error("Caught exception %d while equalizing image!", e);
    }    

    cudaFreeHost(h_rgb_image);
    cudaFree(d_rgb_image);
    cudaFree(d_histogram);
    cudaFree(d_cdf);
    cudaFree(d_cdf_norm);
    cudaFree(d_hsl_image.h);
    cudaFree(d_hsl_image.s);
    cudaFree(d_hsl_image.l);

    for (int i = 0; i < nStreams; i++)
    {
        gpuErrorCheck( cudaStreamDestroy(streams[i]) );
    }

    return e;
}
