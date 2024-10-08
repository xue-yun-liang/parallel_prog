#include <stdio.h>
#include <float.h>
#include "../include/error.cuh"
#include "../include/kernel.cuh"

#ifdef DUSE_DP
typedef double real;
#else
typedef float real;
#endif


const int N = 2048;         // Example size, should be a power of 2 for simplicity
const int BLOCK_SIZE = 128; // Example block size, can be tuned

// version 0: Reduce in CPU
real reduce_cpu(const real *x, const int N)
{
  float sum = 0.0;
  for (int i = 0; i < N; i++)
  {
    sum += x[i];
  }
  return sum;
}

// version 1: a incorrect reduce in gpu, as
__global__ void recude_error(real *d_x, int N)
{
  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  for (int offset = N / 2; offset > 0; offset /= 2)
  {
    // 导致数据覆盖
    if (tid < offset)
      d_x[tid] += d_x[tid + offset];
  }
}

// version 2: a reduce using global memory
__global__ void reduce_global(real *d_x, real *d_y)
{
  const int tid = threadIdx.x;
  real *x = d_x + blockIdx.x * blockDim.x;
  for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
  {
    if (tid < offset)
      x[tid] += x[tid + offset];
    __syncthreads();
  }

  if (tid == 0)
  {
    d_y[blockIdx.x] = x[0];
  }
}

// version 3: a reduce using static shared memory
__global__ void reduce_share(real *d_x, real *d_y)
{
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  const int n = bid * blockDim.x + tid;
  __shared__ real s_y[128];
  s_y[tid] = (n < N) ? d_x[n] : 0.0;
  __syncthreads();

  for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
  {
    if (tid < offset)
      s_y[tid] = s_y[tid + offset];
    __syncthreads();
  }

  if (tid == 0)
  {
    d_y[tid] = s_y[0];
  }
}

// version 4: a reduce using dynmic shared memory
__global__ void reduce_share_(const real *d_x, real *d_y)
{
  // call reduce_share_<<<grid_size, block_size, sizeof(real) * block>>>(x, y);
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  const int n = bid * blockDim.x + tid;
  extern __shared__ real s_y[];
  s_y[tid] = (n < N) ? d_x[n] : 0.0;
  __syncthreads();

  for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
  {
    if (tid < offset)
      s_y[tid] = s_y[tid + offset];
    __syncthreads();
  }

  if (tid == 0)
  {
    d_y[tid] = s_y[0];
  }
}

// version 5: a reduce using atomic func
__global__ void reduce_share_atomic(const real *d_x, real *d_y, int N)
{
  // call reduce_share_<<<grid_size, block_size, sizeof(real) * block>>>(x, y);
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  const int n = bid * blockDim.x + tid;
  extern __shared__ real s_y[];
  s_y[tid] = (n < N) ? d_x[n] : 0.0;
  __syncthreads();

  for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
  {
    if (tid < offset)
      s_y[tid] = s_y[tid + offset];
    __syncthreads();
  }

  if (tid == 0)
  {
    atomicAdd(&d_y[0], s_y[0]);
  }
}

real runreduce(const real *d_x)
{
  const int grid_size = (N + BLOCK_SIZE - 1) / BLOCK_SIZE;
  const int smem = sizeof(real) * BLOCK_SIZE;

  real h_y[1] = {0};
  real *d_y;

  CHECK(cudaMalloc(&d_y, sizeof(real)));
  CHECK(cudaMemcpy(h_y, d_y, sizeof(real), cudaMemcpyHostToDevice));

  reduce_share_atomic<<<grid_size, BLOCK_SIZE, smem>>>(d_x, d_y, N);

  CHECK(cudaMemcpy(d_y, h_y, sizeof(real), cudaMemcpyDeviceToHost));
  CHECK(cudaFree(d_y));

  return h_y[0];
}

// version 6: reduce using __syncwarp
__global__ void reduce_syncwarp(const real *d_x, real *d_y, const int N)
{
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  const int n = bid * blockDim.x + tid;
  extern __shared__ real s_y[];
  s_y[tid] = (n < N) ? d_x[n] : 0.0;
  __syncthreads();

  for (int offset = blockDim.x >> 1; offset >= 32; offset >>= 1)
  {
    if (tid < offset)
    {
      s_y[tid] += s_y[tid + offset];
    }
    __syncthreads();
  }

  for (int offset = 16; offset > 0; offset >>= 1)
  {
    if (tid < offset)
    {
      s_y[tid] += s_y[offset + tid];
    }
    __syncwarp();
  }

  if (tid == 0)
  {
    atomicAdd(d_y, s_y[0]);
  }
}

// version 6: reduce using __shfl_xor_sync
__global__ void reduce_shfl_xor_sync(const real *d_x, real *d_y, const int N)
{
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  const int n = bid * blockDim.x + tid;
  extern __shared__ real s_y[];
  s_y[tid] = (n < N) ? d_x[n] : 0.0;
  __syncthreads();

  for (int offset = blockDim.x >> 1; offset >= 32; offset >>= 1)
  {
    if (tid < offset)
    {
      s_y[tid] += s_y[tid + offset];
    }
    __syncthreads();
  }

  real y = s_y[tid];

  for (int offset = 16; offset > 0; offset >>= 1)
  {
    y += __shfl_xor_sync(uint(-1), y, offset);
  }

  if (tid == 0)
  {
    atomicAdd(d_y, y);
  }
}

void launch_reduce(const real *d_x, real *d_y, const int N)
{
  const int block_size = 256;
  const int grid_size = (N + block_size - 1) / block_size;
  size_t shared_mem_size = block_size * sizeof(real);
  reduce_shfl_xor_sync<<<grid_size, block_size, shared_mem_size>>>(d_x, d_y, N);
}


// Block reduce sum/max/min device helper for Layer/RMS Norm/Softmax etc.
// grid 1D block 1D, grid(N/128), block(128)
template <const int NUM_THREADS>
__device__ __forceinline__ float block_reduce_sum(float val)
{
  // always <= 32 warps per block (limited by 1024 threads per block)
  constexpr int NUM_WARPS = (NUM_THREADS + WARP_SIZE - 1) / WARP_SIZE;
  int warp = threadIdx.x / WARP_SIZE;
  int lane = threadIdx.x % WARP_SIZE;
  static __shared__ float shared[NUM_WARPS];

  val = warp_reduce_sum<WARP_SIZE>(val);
  if (lane == 0)
    shared[warp] = val;
  __syncthreads();
  val = (lane < NUM_WARPS) ? shared[lane] : 0.0f;
  val = warp_reduce_sum<NUM_WARPS>(val);
  return val;
}

template <const int NUM_THREADS>
__device__ __forceinline__ float block_reduce_max(float val)
{
  // always <= 32 warps per block (limited by 1024 threads per block)
  constexpr int NUM_WARPS = (NUM_THREADS + WARP_SIZE - 1) / WARP_SIZE;
  int warp = threadIdx.x / WARP_SIZE;
  int lane = threadIdx.x % WARP_SIZE;
  static __shared__ float shared[NUM_WARPS];

  val = warp_reduce_max<WARP_SIZE>(val);
  if (lane == 0)
    shared[warp] = val;
  __syncthreads();
  val = (lane < NUM_WARPS) ? shared[lane] : -FLT_MAX;
  val = warp_reduce_max<NUM_WARPS>(val);
  return val;
}


// Block All Reduce Sum
// grid(N/128), block(128)
// a: Nx1, y=sum(a)
template <const int NUM_THREADS>
__global__ void block_all_reduce_sum(float *a, float *y, int N)
{
  int tid = threadIdx.x;
  int idx = blockIdx.x * NUM_THREADS + tid;
  constexpr int NUM_WARPS = (NUM_THREADS + WARP_SIZE - 1) / WARP_SIZE;
  __shared__ float reduce_smem[NUM_WARPS];
  // keep the data in register is enougth for warp operaion.
  float sum = (idx < N) ? a[idx] : 0.0f;
  int warp = tid / WARP_SIZE;
  int lane = tid % WARP_SIZE;
  // perform warp sync reduce.
  sum = warp_reduce_sum<WARP_SIZE>(sum);
  // warp leaders store the data to shared memory.
  if (lane == 0)
    reduce_smem[warp] = sum;
  __syncthreads(); // make sure the data is in shared memory.
  // the first warp compute the final sum.
  sum = (lane < NUM_WARPS) ? reduce_smem[lane] : 0.0f;
  if (warp == 0)
    sum = warp_reduce_sum<NUM_WARPS>(sum);
  if (tid == 0)
    atomicAdd(y, sum);
}

// Block All Reduce Sum + float4
// grid(N/128), block(128/4)
// a: Nx1, y=sum(a)
template <const int NUM_THREADS>
__global__ void block_all_reduce_sum_vec4(float *a, float *y, int N)
{
  int tid = threadIdx.x;
  int idx = (blockIdx.x * NUM_THREADS + tid) * 4;
  constexpr int NUM_WARPS = (NUM_THREADS + WARP_SIZE - 1) / WARP_SIZE;
  __shared__ float reduce_smem[NUM_WARPS];

  float4 reg_a = FLOAT4(a[idx]);
  // keep the data in register is enougth for warp operaion.
  float sum = (idx < N) ? (reg_a.x + reg_a.y + reg_a.z + reg_a.w) : 0.0f;
  int warp = tid / WARP_SIZE;
  int lane = tid % WARP_SIZE;
  // perform warp sync reduce.
  sum = warp_reduce_sum<WARP_SIZE>(sum);
  // warp leaders store the data to shared memory.
  if (lane == 0)
    reduce_smem[warp] = sum;
  __syncthreads(); // make sure the data is in shared memory.
  // the first warp compute the final sum.
  sum = (lane < NUM_WARPS) ? reduce_smem[lane] : 0.0f;
  if (warp == 0)
    sum = warp_reduce_sum<NUM_WARPS>(sum);
  if (tid == 0)
    atomicAdd(y, sum);
}

real run_reduce(const real *h_x, real *h_y, const int N)
{
  // const int block_size = 256;
  // const int grid_size = (N + block_size - 1) / block_size;

  const int grid_size(N / 128);
  const int block_size(128 / 4);
  size_t shared_mem_size = block_size * sizeof(real);

  real *d_x, *d_y;
  cudaMalloc(&d_x, N * sizeof(real));
  cudaMalloc(&d_y, sizeof(real));

  cudaMemcpy(d_x, h_x, N * sizeof(real), cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, h_y, sizeof(real), cudaMemcpyHostToDevice);

  block_all_reduce_sum_vec4<<<grid_size, block_size, shared_mem_size>>>(d_x, d_y, N);

  cudaMemcpy(h_y, d_y, sizeof(real), cudaMemcpyDeviceToHost);

  cudaFree(d_x);
  cudaFree(d_y);
  return *h_y;
}


void reduce_wrapper(real *d_x, real *d_y, int size)
{
  int gridSize = (size + BLOCK_SIZE - 1) / BLOCK_SIZE;
  reduce_global<<<gridSize, BLOCK_SIZE>>>(d_x, d_y);
}

int main()
{

  return 0;
}