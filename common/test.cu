#include <iostream>
#include <vector>
#include <cuda_runtime.h>
#include "sps.cu.h"
#include "util.cu.h"

struct Add {
    __device__ inline int operator()(int a, int b) const {
        return a + b;
    }
};

template<typename T, typename I, typename OP, I BLOCK_SIZE, I ITEMS_PER_THREAD>
__global__ void
scanBlocks(T* d_in,
           T* d_out,
           OP op,
           T ne,
           const I size) {
    volatile __shared__ T block[ITEMS_PER_THREAD * BLOCK_SIZE];
	volatile __shared__ T block_aux[BLOCK_SIZE];
    I glb_offs = blockIdx.x * BLOCK_SIZE * ITEMS_PER_THREAD;

    glbToShmemCpy<T, I, ITEMS_PER_THREAD>(glb_offs, size, ne, d_in, block);

    scanBlock<T, I, OP, ITEMS_PER_THREAD>(block, block_aux, op);
    
    shmemToGlbCpy<T, I, ITEMS_PER_THREAD>(glb_offs, size, d_out, block);
}

template<typename I>
void testBlocks(I size) {
    const I BLOCK_SIZE = 32;
    const I ITEMS_PER_THREAD = 4;
    const I GRID_SIZE = (size + BLOCK_SIZE * ITEMS_PER_THREAD - 1) / (BLOCK_SIZE * ITEMS_PER_THREAD);
    const I ARRAY_BYTES = size * sizeof(int);

    std::vector<int> h_in(size);
    std::vector<int> h_out(size, 0);

    for (I i = 0; i < size; ++i) {
        h_in[i] = rand() % 10;
    }

    int *d_in, *d_out;
    gpuAssert(cudaMalloc((void**)&d_in, ARRAY_BYTES));
    gpuAssert(cudaMalloc((void**)&d_out, ARRAY_BYTES));

    gpuAssert(cudaMemcpy(d_in, h_in.data(), ARRAY_BYTES, cudaMemcpyHostToDevice));

    Add op = Add();
    
    scanBlocks<int, I, Add, BLOCK_SIZE, ITEMS_PER_THREAD><<<GRID_SIZE, BLOCK_SIZE>>>(d_in, d_out, op, 0, size);
    cudaDeviceSynchronize();

    gpuAssert(cudaMemcpy(h_out.data(), d_out, ARRAY_BYTES, cudaMemcpyDeviceToHost));

    int acc = 0;
    bool test_passes = true;

    for (I i = 0; i < size; ++i) {
        if (i % (BLOCK_SIZE * ITEMS_PER_THREAD) == 0) {
            acc = h_in[i];
        } else {
            acc += h_in[i];
        }
        test_passes &= h_out[i] == acc;
    }

    if (test_passes) {
        std::cout << "Block Addition Scan Test Passed using " << size << " int32.\n";
    } else {
        std::cout << "Block Addition Scan Test Failed using " << size << " int32.\n";
    }

    gpuAssert(cudaFree(d_in));
    gpuAssert(cudaFree(d_out));
}

template<typename T, typename I, typename OP, I BLOCK_SIZE, I ITEMS_PER_THREAD>
__global__ void
spsScan(T* d_in,
     T* d_out,
     volatile State<T>* states,
     I size,
     OP op,
     const T ne,
     volatile uint32_t* dyn_idx_ptr) {
    volatile __shared__ T block[ITEMS_PER_THREAD * BLOCK_SIZE];
	volatile __shared__ T block_aux[BLOCK_SIZE];
    
    uint32_t dyn_idx = dynamicIndex<uint32_t>(dyn_idx_ptr);
    I glb_offs = dyn_idx * BLOCK_SIZE * ITEMS_PER_THREAD;

    glbToShmemCpy<T, I, ITEMS_PER_THREAD>(glb_offs, size, ne, d_in, block);

    scan<T, I, OP, ITEMS_PER_THREAD>(block, block_aux, states, op, ne, dyn_idx);

    shmemToGlbCpy<T, I, ITEMS_PER_THREAD>(glb_offs, size, d_out, block);
    
}

void benchMemcpy(size_t size) {
    const size_t WARMUP_RUNS = 50;
    const size_t RUNS = 10;
    const size_t ARRAY_BYTES = size * sizeof(int);
    int *d_in, *d_out;

    gpuAssert(cudaMalloc((void**)&d_in, ARRAY_BYTES));
    gpuAssert(cudaMalloc((void**)&d_out, ARRAY_BYTES));

    for (size_t i = 0; i < WARMUP_RUNS; ++i) {
        cudaMemcpy(d_out, d_in, size, cudaMemcpyDeviceToDevice);
        cudaDeviceSynchronize();
    }

    timeval * temp = (timeval *) malloc(sizeof(timeval) * RUNS);
    timeval prev; 
    timeval curr;
    timeval t_diff;

    for (size_t i = 0; i < RUNS; ++i) {
        gettimeofday(&prev, NULL);
        cudaMemcpy(d_out, d_in, ARRAY_BYTES, cudaMemcpyDeviceToDevice);
        cudaDeviceSynchronize();
        gettimeofday(&curr, NULL);
        timeval_subtract(&t_diff, &curr, &prev);
        temp[i] = t_diff;
    }
 
    compute_descriptors(temp, RUNS, 2 * ARRAY_BYTES);
    free(temp);
    gpuAssert(cudaFree(d_in));
    gpuAssert(cudaFree(d_out));
}

template<typename I>
void testScan(I size) {
    const I BLOCK_SIZE = 256;
    const I ITEMS_PER_THREAD = 30;
    const I NUM_LOGICAL_BLOCKS = (size + BLOCK_SIZE * ITEMS_PER_THREAD - 1) / (BLOCK_SIZE * ITEMS_PER_THREAD);
    const I ARRAY_BYTES = size * sizeof(int);
    const I STATES_BYTES = NUM_LOGICAL_BLOCKS * sizeof(State<int>);
    const I WARMUP_RUNS = 1000;
    const I RUNS = 10;

     std::cout << "Testing and Benching Addition Scan using " << size << " int32.\n";

    std::vector<int> h_in(size);
    std::vector<int> h_out(size, 0);

    for (I i = 0; i < size; ++i) {
        h_in[i] = rand() % 10;
    }

    uint32_t* d_dyn_idx_ptr;
    int *d_in, *d_out;
    State<int>* d_states;
    gpuAssert(cudaMalloc( (void**)&d_dyn_idx_ptr, sizeof(uint32_t)));
    cudaMemset(d_dyn_idx_ptr, 0, sizeof(uint32_t));
    gpuAssert(cudaMalloc((void**)&d_states, STATES_BYTES));
    gpuAssert(cudaMalloc((void**)&d_in, ARRAY_BYTES));
    gpuAssert(cudaMalloc((void**)&d_out, ARRAY_BYTES));

    gpuAssert(cudaMemcpy(d_in, h_in.data(), ARRAY_BYTES, cudaMemcpyHostToDevice));

    Add op = Add();
    
    for (I i = 0; i < WARMUP_RUNS; ++i) {
        spsScan<int, I, Add, BLOCK_SIZE, ITEMS_PER_THREAD><<<NUM_LOGICAL_BLOCKS, BLOCK_SIZE>>>(d_in, d_out, d_states, size, op, 0, d_dyn_idx_ptr);
        cudaDeviceSynchronize();
        cudaMemset(d_dyn_idx_ptr, 0, sizeof(uint32_t));
    }

    timeval * temp = (timeval *) malloc(sizeof(timeval) * RUNS);
    timeval prev;
    timeval curr;
    timeval t_diff;

    for (I i = 0; i < RUNS; ++i) {
        gettimeofday(&prev, NULL);
        spsScan<int, I, Add, BLOCK_SIZE, ITEMS_PER_THREAD><<<NUM_LOGICAL_BLOCKS, BLOCK_SIZE>>>(d_in, d_out, d_states, size, op, 0, d_dyn_idx_ptr);
        cudaDeviceSynchronize();
        gettimeofday(&curr, NULL);
        timeval_subtract(&t_diff, &curr, &prev);
        temp[i] = t_diff;
        cudaMemset(d_dyn_idx_ptr, 0, sizeof(uint32_t));
    }

    compute_descriptors(temp, RUNS, 2 * ARRAY_BYTES);
    free(temp);

    spsScan<int, I, Add, BLOCK_SIZE, ITEMS_PER_THREAD><<<NUM_LOGICAL_BLOCKS, BLOCK_SIZE>>>(d_in, d_out, d_states, size, op, 0, d_dyn_idx_ptr);
    cudaDeviceSynchronize();

    gpuAssert(cudaMemcpy(h_out.data(), d_out, ARRAY_BYTES, cudaMemcpyDeviceToHost));

    int acc = 0;

    bool test_passes = true;

    for (I i = 0; i < size; ++i) {
        acc += h_in[i];
        test_passes &= h_out[i] == acc;
    }

    if (test_passes) {
        std::cout << "Scan Test Passed.\n";
    } else {
        std::cout << "Scan Test Failed.\n";
    }

    gpuAssert(cudaFree(d_in));
    gpuAssert(cudaFree(d_out));
    gpuAssert(cudaFree(d_states));
    gpuAssert(cudaFree(d_dyn_idx_ptr));
}

int main() {
    info();
    
    std::cout << "\nTesting Block Wide Scan:\n";
    testBlocks<uint32_t>(1 << 6);
    testBlocks<uint32_t>(1 << 16);
    testBlocks<uint32_t>(1 << 26);

    testBlocks<uint32_t>(1000);
    testBlocks<uint32_t>(100000);
    testBlocks<uint32_t>(10000000);
    std::cout << "\n";
    
    std::cout << "Testing and Benching Device Wide Single Pass Scan:";
    testScan<uint32_t>(1 << 8);
    std::cout << "\n";
    testScan<uint32_t>(1 << 16);
    std::cout << "\n";
    testScan<uint32_t>(1 << 26);
    std::cout << "\n";

    testScan<uint32_t>(1000);
    std::cout << "\n";
    testScan<uint32_t>(100000);
    std::cout << "\n";
    testScan<uint32_t>(100000000);
    std::cout << "\n";

    std::cout << "Testing and Benching cudaMemcpy using device to device on 500MiB of int32:\n";
    benchMemcpy(131072000);
    std::cout << "\nTesting and Benching Scan on 500MiB of int32: \n";
    testScan<uint32_t>(131072000);
    std::cout << std::flush;

    gpuAssert(cudaPeekAtLastError());
    return 0;
}
