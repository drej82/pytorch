#include "THCTensorMath.h"
#include "THCGeneral.h"
#include "THCTensorRandom.h"

#include <thrust/fill.h>
#include <thrust/functional.h>
#include <thrust/reduce.h>
#include <thrust/inner_product.h>

#define NB_THREADS_PER_BLOCK 256

void THCudaTensor_fill(THCudaTensor *self_, float value)
{
  THCudaTensor *self = THCudaTensor_newContiguous(self_);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  thrust::fill(self_data, self_data+THCudaTensor_nElement(self), value);

  THCudaTensor_freeCopyTo(self, self_);
}

void THCudaTensor_zero(THCudaTensor *self_)
{
  THCudaTensor *self = THCudaTensor_newContiguous(self_);
  cudaMemset(THCudaTensor_data(self), 0, sizeof(float)*THCudaTensor_nElement(self));
  THCudaTensor_freeCopyTo(self, self_);
}

struct addvalue_functor
{
  const float value;

  addvalue_functor(float value_) : value(value_) {}

    __host__ __device__ float operator()(const float& x) const
  {
    return (x+value);
  }
};

void THCudaTensor_add(THCudaTensor *self_, float value)
{
  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    thrust::device_ptr<float> self_data(THCudaTensor_data(self));

    thrust::transform(self_data, self_data+size, self_data, addvalue_functor(value));

    THCudaTensor_freeCopyTo(self, self_);
  }
}

void THCudaTensor_mul(THCudaTensor *self_, float value)
{
  THCudaTensor *self = THCudaTensor_newContiguous(self_);

  cublasSscal(THCudaTensor_nElement(self), value, THCudaTensor_data(self), 1);
  THCublasCheck();

  THCudaTensor_freeCopyTo(self, self_);
}

void THCudaTensor_div(THCudaTensor *self_, float value)
{
  THCudaTensor *self = THCudaTensor_newContiguous(self_);

  cublasSscal(THCudaTensor_nElement(self), 1/value, THCudaTensor_data(self), 1);
  THCublasCheck();

  THCudaTensor_freeCopyTo(self, self_);
}

void THCudaTensor_cadd(THCudaTensor *self_, float value, THCudaTensor *src)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src), 3, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    src = THCudaTensor_newContiguous(src);

    cublasSaxpy(THCudaTensor_nElement(self), value, THCudaTensor_data(src), 1, THCudaTensor_data(self), 1);
    THCublasCheck();

    THCudaTensor_free(src);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

void THCudaTensor_cadd_tst(THCudaTensor *self_, THCudaTensor* src1, float value, THCudaTensor *src2)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src1), 3, "size do not match");
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src2), 3, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);

    src1 = THCudaTensor_newContiguous(src1);
    src2 = THCudaTensor_newContiguous(src2);

    THCudaTensor_copy(self, src1);
    cublasSaxpy(THCudaTensor_nElement(self), value, THCudaTensor_data(src2), 1, THCudaTensor_data(self), 1);
    THCublasCheck();

    THCudaTensor_free(src1);
    THCudaTensor_free(src2);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

void THCudaTensor_cmul(THCudaTensor *self_, THCudaTensor *src1, THCudaTensor *src2)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src1), 2, "size do not match");
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src2), 3, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    src1 = THCudaTensor_newContiguous(src1);
    src2 = THCudaTensor_newContiguous(src2);
    thrust::device_ptr<float> self_data(THCudaTensor_data(self));
    thrust::device_ptr<float> src1_data(THCudaTensor_data(src1));
    thrust::device_ptr<float> src2_data(THCudaTensor_data(src2));

    thrust::transform(src2_data, src2_data+size, src1_data, self_data, thrust::multiplies<float>());

    THCudaTensor_free(src1);
    THCudaTensor_free(src2);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

void THCudaTensor_cdiv(THCudaTensor *self_, THCudaTensor *src)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src), 2, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    src = THCudaTensor_newContiguous(src);
    thrust::device_ptr<float> self_data(THCudaTensor_data(self));
    thrust::device_ptr<float> src_data(THCudaTensor_data(src));

    thrust::transform(self_data, self_data+size, src_data, self_data, thrust::divides<float>());

    THCudaTensor_free(src);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

__global__ void THCudaTensor_kernel_addcmul(float *data, float value, float *src1, float *src2, long size)
{
  long k = (((blockIdx.y * gridDim.x) + blockIdx.x) * blockDim.x) + threadIdx.x;
  
  if(k < size)
    data[k] += value*src1[k]*src2[k];
}


void THCudaTensor_addcmul(THCudaTensor *self_, float value, THCudaTensor *src1, THCudaTensor *src2)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src1), 3, "size do not match");
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src2), 4, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    src1 = THCudaTensor_newContiguous(src1);
    src2 = THCudaTensor_newContiguous(src2);

    int nBlockPerRow, nBlockPerColumn, nThreadPerBlock;
    THCudaGetGridSize(&nBlockPerRow, &nBlockPerColumn, &nThreadPerBlock, size);
    dim3 threads(nThreadPerBlock);
    dim3 grid(nBlockPerRow, nBlockPerColumn);

    THCudaTensor_kernel_addcmul<<<grid, threads>>>(THCudaTensor_data(self), value, THCudaTensor_data(src1), THCudaTensor_data(src2), size);

    cudaError errcode = cudaGetLastError();
    if(errcode != cudaSuccess)
      THError(cudaGetErrorString(errcode));

    THCudaTensor_free(src1);
    THCudaTensor_free(src2);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

__global__ void THCudaTensor_kernel_addcdiv(float *data, float value, float *src1, float *src2, long size)
{
  long k = (((blockIdx.y * gridDim.x) + blockIdx.x) * blockDim.x) + threadIdx.x;

  if(k < size)
    data[k] += value*src1[k]/src2[k];
}


void THCudaTensor_addcdiv(THCudaTensor *self_, float value, THCudaTensor *src1, THCudaTensor *src2)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src1), 3, "size do not match");
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src2), 4, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    src1 = THCudaTensor_newContiguous(src1);
    src2 = THCudaTensor_newContiguous(src2);

    int nBlockPerRow, nBlockPerColumn, nThreadPerBlock;
    THCudaGetGridSize(&nBlockPerRow, &nBlockPerColumn, &nThreadPerBlock, size);
    dim3 threads(nThreadPerBlock);
    dim3 grid(nBlockPerRow, nBlockPerColumn);

    THCudaTensor_kernel_addcdiv<<<grid, threads>>>(THCudaTensor_data(self), value, THCudaTensor_data(src1), THCudaTensor_data(src2), size);

    cudaError errcode = cudaGetLastError();
    if(errcode != cudaSuccess)
      THError(cudaGetErrorString(errcode));

    THCudaTensor_free(src1);
    THCudaTensor_free(src2);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

float THCudaTensor_dot(THCudaTensor *self, THCudaTensor *src)
{
  THArgCheck(THCudaTensor_nElement(self) == THCudaTensor_nElement(src), 2, "size do not match");

  {
    self = THCudaTensor_newContiguous(self);
    src = THCudaTensor_newContiguous(src);

    float result = cublasSdot(THCudaTensor_nElement(self),
                              THCudaTensor_data(self), 1,
                              THCudaTensor_data(src), 1);

    THCublasCheck();

    THCudaTensor_free(src);
    THCudaTensor_free(self);

    return result;
  }
}

float THCudaTensor_minall(THCudaTensor *self)
{
  self = THCudaTensor_newContiguous(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  float result = thrust::reduce(self_data, self_data+THCudaTensor_nElement(self), (float)(THInf), thrust::minimum<float>());

  THCudaTensor_free(self);
  return result;
}

float THCudaTensor_maxall(THCudaTensor *self)
{
  self = THCudaTensor_newContiguous(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  float result = thrust::reduce(self_data, self_data+THCudaTensor_nElement(self), (float)(-THInf), thrust::maximum<float>());

  THCudaTensor_free(self);
  return result;
}

float THCudaTensor_sumall(THCudaTensor *self)
{
  self = THCudaTensor_newContiguous(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  float result = thrust::reduce(self_data, self_data+THCudaTensor_nElement(self), (float)(0), thrust::plus<float>());

  THCudaTensor_free(self);
  return result;
}



struct dim4 {
    unsigned arr[4];

    __host__ dim4(unsigned init=0) {
        for(unsigned i=0; i<4; i++) { arr[i] = init; }
    }

    __host__ __device__ unsigned& operator[](const unsigned& idx) { return arr[idx]; }
};



/* Reduce one of the outer dimensions of a tensor
 *
 * For an n-d tensor (n <= 4) where the reduction is *not* along the innermost
 * dimension:
 *
 * - block.x and grid.x make up the innermost dimension;
 * - The reduced dimension is looped over inside a block; and
 * - grid.y and grid.z are the remaining two dimensions (if any).
 * - block.y and block.z are not used as we're limited to 512 or 1024 threads
 *   in the block.
 *
 * For sizes/strides, index 3 is the reduced dimension, while the remaining
 * indices are for the remaining dimensions with index 0 the innermost dimension.
 *
 * Reduction along the innermost dimension is handled in a separate kernel.
 */
template<class Op, typename T>
__global__ void THCudaTensor_kernel_reduceOuterDim(float *tgt, float *src_,
        dim4 src_stride, dim4 tgt_stride, dim4 size, Op op, T init)
{
  const size_t reduce = 3;
  uint col = blockIdx.x * blockDim.x + threadIdx.x;
  float *src = src_ + blockIdx.z * src_stride[2] + blockIdx.y * src_stride[1] + col;

  if(col < size[0]) {
    T acc = init;
    for(uint i=0; i < size[reduce]; i++) {
      acc = op((T) acc, (T) *src);
      src += src_stride[reduce];
    }
    tgt[blockIdx.z * tgt_stride[2] + blockIdx.y * tgt_stride[1] + col] = float(acc);
  }
}


template<class Op, typename T>
__host__ void THCudaTensor_reduceOuterDim(THCudaTensor *tgt, THCudaTensor *src, long rdim, Op op, T init)
{
  const size_t reduce = 3;
  dim4 src_stride(0);
  dim4 tgt_stride(0);
  dim4 size(1);

  uint ndim = THCudaTensor_nDimension(src);
  for(uint idim=0, o=ndim-2; idim < ndim; idim++) {
    uint odim = idim == rdim ? reduce : o--;
    src_stride[odim] = THCudaTensor_stride(src, idim);
    tgt_stride[odim] = THCudaTensor_stride(tgt, idim);
    size[odim]       = THCudaTensor_size(src, idim);
  }

  const uint nThreadPerBlock = 256;
  uint nBlockPerColumn = (size[0] + nThreadPerBlock - 1) / nThreadPerBlock;
  dim3 threads(nThreadPerBlock);
  dim3 grid(nBlockPerColumn, size[1], size[2]);

  THCudaTensor_kernel_reduceOuterDim<<<grid, threads>>>(THCudaTensor_data(tgt),
          THCudaTensor_data(src), src_stride, tgt_stride, size, op, init);
  cudaError errcode = cudaGetLastError();
  if(errcode != cudaSuccess) {
    THError(cudaGetErrorString(errcode));
  }
}



/* Reduce the innermost dimension of a tensor
 *
 * For an n-d tensor (n <= 4) where the reduction is along the innermost dimension:
 *
 * - block.x is the innermost dimension, i.e. dimension 0;
 * - block.y and grid.y make up dimension 1; and
 * - grid.x and grid z are the remaining two outer dimensions (if any)
 *
 * Reduction along other dimensions is handled in a separate kernel.
 */
template<class Op, typename T>
__global__ void THCudaTensor_kernel_reduceInnermostDim(float *tgt, float *src_,
        dim4 src_stride, dim4 tgt_stride, dim4 size, Op op, T init)
{
  __shared__ float sbuf[16][32]; // 8kB

  T acc = init;

  uint row = blockIdx.y * blockDim.y + threadIdx.y;
  float *src = src_ + blockIdx.z * src_stride[3] + blockIdx.x * src_stride[2] + row * src_stride[1];
  bool reducing = threadIdx.x < blockDim.y
                && blockIdx.y * blockDim.y + threadIdx.x < size[1]
                && threadIdx.y == 0;

  for(uint bCol=0; bCol < size[0]; bCol += blockDim.x) {

    sbuf[threadIdx.y][threadIdx.x] = init;
    uint col = bCol + threadIdx.x;
    if(row < size[1] && col < size[0]) {
      sbuf[threadIdx.y][threadIdx.x] = src[col];
    }
    __syncthreads();

    if(reducing) {
      for(uint x=0; x < blockDim.x; ++x) {
        /* Could eliminate shared memory bank conflicst hare by using modulo 32
         * addressing: (x + threadIdx) % 32. However, due to the memory-bound
         * nature of the kernel this makes no difference to performance */
        acc = op((T) acc, (T) sbuf[threadIdx.x][x]);
      }
    }
    __syncthreads(); // to avoid sbuf being cleared too early
  }

  if(reducing) {
    uint row = blockIdx.y * blockDim.y + threadIdx.x;
    uint tgt_offset = blockIdx.z * tgt_stride[3] + blockIdx.x * tgt_stride[2];
    tgt[tgt_offset + row] = float(acc);
  }
}



template<class Op, typename T>
__host__ void THCudaTensor_reduceInnermostDim(THCudaTensor *tgt, THCudaTensor *src, Op op, T init)
{
  dim4 src_stride(0);
  dim4 tgt_stride(0);
  dim4 size(1);

  uint ndim = THCudaTensor_nDimension(src);
  for(uint dim=0; dim < ndim; dim++) {
    uint odim = ndim - 1 - dim;
    src_stride[odim] = THCudaTensor_stride(src, dim);
    tgt_stride[odim] = THCudaTensor_stride(tgt, dim);
    size[odim]       = THCudaTensor_size(src, dim);
  }

  dim3 threads(32, 16);
  uint nBlockPerRow = (size[1] + threads.y - 1) / threads.y;
  dim3 grid(size[2], nBlockPerRow, size[3]);

  THCudaTensor_kernel_reduceInnermostDim<<<grid, threads>>>(THCudaTensor_data(tgt),
          THCudaTensor_data(src), src_stride, tgt_stride, size, op, init);
  cudaError errcode = cudaGetLastError();
  if(errcode != cudaSuccess) {
    THError(cudaGetErrorString(errcode));
  }
}


template<class Op, typename T>
void THCudaTensor_reduceDim(THCudaTensor *self_, THCudaTensor *src, long dimension, Op op, T init)
{
  THArgCheck(dimension >= 0 && dimension < THCudaTensor_nDimension(src), 3, "dimension out of range");
  THArgCheck(THCudaTensor_nDimension(src) <= 4, 2, "too many dimensions (>4)");

  THLongStorage *dim = THCudaTensor_newSizeOf(src);
  THLongStorage_set(dim, dimension, 1);
  THCudaTensor_resize(self_, dim, NULL);
  THLongStorage_free(dim);

  THCudaTensor *self = THCudaTensor_newContiguous(self_);
  src = THCudaTensor_newContiguous(src);

  if(dimension == THCudaTensor_nDimension(src)-1) {
    THCudaTensor_reduceInnermostDim(self, src, op, init);
  } else {
    THCudaTensor_reduceOuterDim(self, src, dimension, op, init);
  }

  THCudaTensor_free(src);
  THCudaTensor_freeCopyTo(self, self_);
}


void THCudaTensor_sum(THCudaTensor *self, THCudaTensor *src, long dimension)
{
  return THCudaTensor_reduceDim(self, src, dimension, thrust::plus<double>(), 0.0);
}


void THCudaTensor_max(THCudaTensor *self, THCudaTensor *src, long dimension)
{
  const float minfloat32 = 1.175494351e-38f;
  return THCudaTensor_reduceDim(self, src, dimension, thrust::maximum<float>(), minfloat32);
}


void THCudaTensor_min(THCudaTensor *self, THCudaTensor *src, long dimension)
{
  const float maxfloat32 = 3.402823466e+38f;
  return THCudaTensor_reduceDim(self, src, dimension, thrust::minimum<float>(), maxfloat32);
}


void THCudaTensor_addmv(THCudaTensor *self, float beta, float alpha, THCudaTensor *mat, THCudaTensor *vec)
{
  if( (mat->nDimension != 2) || (vec->nDimension != 1) )
    THError("matrix and vector expected");

  if( mat->size[1] != vec->size[0] )
    THError("size mismatch");

  if(self->nDimension != 1)
    THError("size mismatch");

  if( self->size[0] != mat->size[0] )
    THError("size mismatch");

  if(mat->stride[0] == 1)
  {
    cublasSgemv('n', mat->size[0], mat->size[1],
                alpha, THCudaTensor_data(mat), mat->stride[1],
                THCudaTensor_data(vec), vec->stride[0],
                beta, THCudaTensor_data(self), self->stride[0]);
  }
  else if(mat->stride[1] == 1)
  {
    cublasSgemv('t',  mat->size[1], mat->size[0],
                alpha, THCudaTensor_data(mat), mat->stride[0],
                THCudaTensor_data(vec), vec->stride[0],
                beta, THCudaTensor_data(self), self->stride[0]);
  }
  else
  {
    mat = THCudaTensor_newContiguous(mat);
    
    cublasSgemv('t',  mat->size[1], mat->size[0],
                alpha, THCudaTensor_data(mat), mat->stride[0],
                THCudaTensor_data(vec), vec->stride[0],
                beta, THCudaTensor_data(self), self->stride[0]);
    
    THCudaTensor_free(mat);
  }

  THCublasCheck();  
}

void THCudaTensor_addmm(THCudaTensor *self, float beta, float alpha, THCudaTensor *m1, THCudaTensor *m2)
{
  char transpose, transpose_m1, transpose_m2;
  THCudaTensor *self_, *m1_, *m2_;

  if( (m1->nDimension != 2) || (m2->nDimension != 2) ) 
    THError("matrix and matrix expected"); 

  if(self->nDimension != 2)
    THError("size mismatch"); 

  if( (self->size[0] != m1->size[0]) || (self->size[1] != m2->size[1]) || (m1->size[1] != m2->size[0]) ) 
    THError("size mismatch"); 

  /* self */
  if(self->stride[0] == 1)
  {
    transpose = 'n';
    self_ = self;
  }
  else if(self->stride[1] == 1)
  {
    THCudaTensor *swap = m2;
    m2 = m1;
    m1 = swap;
    THCudaTensor_transpose(self, NULL, 0, 1);
    THCudaTensor_transpose(m1, NULL, 0, 1);
    THCudaTensor_transpose(m2, NULL, 0, 1);
    transpose = 't';
    self_ = self;
  }
  else
  {
    transpose = 'n';
    THCudaTensor_transpose(self, NULL, 0, 1);
    self_ = THCudaTensor_newClone(self);
    THCudaTensor_transpose(self, NULL, 0, 1);
    THCudaTensor_transpose(self_, NULL, 0, 1);
  }

  /* m1 */
  if(m1->stride[0] == 1)
  {
    transpose_m1 = 'n';
    m1_ = m1;
  }
  else if(m1->stride[1] == 1)
  {
    transpose_m1 = 't';
    m1_ = m1;
  }
  else
  {
    transpose_m1 = 't';
    m1_ = THCudaTensor_newContiguous(m1);
  }

  /* m2 */
  if(m2->stride[0] == 1)
  {
    transpose_m2 = 'n';
    m2_ = m2;
  }
  else if(m2->stride[1] == 1)
  {
    transpose_m2 = 't';
    m2_ = m2;
  }
  else
  {
    transpose_m2 = 't';
    m2_ = THCudaTensor_newContiguous(m2);
  }

  /* do the operation */
  cublasSgemm(transpose_m1,
              transpose_m2,
              self_->size[0],
              self_->size[1],
              m1_->size[1],
              alpha,
              THCudaTensor_data(m1_),
              (transpose_m1 == 'n' ? m1_->stride[1] : m1_->stride[0]),
              THCudaTensor_data(m2_),
              (transpose_m2 == 'n' ? m2_->stride[1] : m2_->stride[0]),
              beta,
              THCudaTensor_data(self_),
              self_->stride[1]);

  THCublasCheck();

  /* free intermediate variables */
  if(m1_ != m1)
    THCudaTensor_free(m1_);

  if(m2_ != m2)
    THCudaTensor_free(m2_);

  if(self_ != self)
    THCudaTensor_freeCopyTo(self_, self);

  if(transpose == 't')
  {
    THCudaTensor_transpose(self, NULL, 0, 1);
    THCudaTensor_transpose(m1, NULL, 0, 1);
    THCudaTensor_transpose(m2, NULL, 0, 1);
  }
}

void THCudaTensor_addr(THCudaTensor *self, float alpha, THCudaTensor *vec1, THCudaTensor *vec2)
{
  if( (vec1->nDimension != 1) || (vec2->nDimension != 1) )
    THError("vector and vector expected");

  if(self->nDimension != 2)
    THError("size mismatch");

  if( (self->size[0] != vec1->size[0]) || (self->size[1] != vec2->size[0]) )
    THError("size mismatch");

  if(self->stride[0] == 1)
  {
    cublasSger(vec1->size[0], vec2->size[0],
               alpha, THCudaTensor_data(vec1), vec1->stride[0],
               THCudaTensor_data(vec2), vec2->stride[0],
               THCudaTensor_data(self), self->stride[1]);
  }
  else if(self->stride[1] == 1)
  {
    cublasSger(vec2->size[0], vec1->size[0],
               alpha, THCudaTensor_data(vec2), vec2->stride[0],
               THCudaTensor_data(vec1), vec1->stride[0],
               THCudaTensor_data(self), self->stride[0]);
  }
  else
  {
    THCudaTensor *cself = THCudaTensor_newClone(self);

    cublasSger(vec2->size[0], vec1->size[0],
               alpha, THCudaTensor_data(vec2), vec2->stride[0],
               THCudaTensor_data(vec1), vec1->stride[0],
               THCudaTensor_data(cself), cself->stride[0]);

    THCudaTensor_freeCopyTo(cself, self);
  }

  THCublasCheck();
}

#define IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(NAME, CFUNC)                   \
  struct NAME##_functor                                                \
  {                                                                     \
    __host__ __device__ float operator()(const float& x) const          \
    {                                                                   \
      return CFUNC(x);                                                  \
    }                                                                   \
  };                                                                    \
                                                                        \
  void THCudaTensor_##NAME(THCudaTensor *self_)                         \
  {                                                                     \
    THCudaTensor *self = THCudaTensor_newContiguous(self_);             \
    long size = THCudaTensor_nElement(self);                            \
    thrust::device_ptr<float> self_data(THCudaTensor_data(self));       \
                                                                        \
    thrust::transform(self_data, self_data+size, self_data, NAME##_functor()); \
                                                                        \
    THCudaTensor_freeCopyTo(self, self_);                               \
  }

IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(log, log)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(log1p, log1p)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(exp, exp)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(cos, cos)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(acos, acos)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(cosh, cosh)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(sin, sin)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(asin, asin)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(sinh, sinh)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(tan, tan)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(atan, atan)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(tanh, tanh)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(sqrt, sqrt)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(ceil, ceil)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(floor, floor)
IMPLEMENT_CUDA_TENSOR_BASIC_FUNC(abs, fabs)

struct pow_functor
{
  const float value;

  pow_functor(float value_) : value(value_) {}

    __host__ __device__ float operator()(const float& x) const
  {
    return pow(x, value);
  }
};

void THCudaTensor_pow(THCudaTensor *self_, THCudaTensor *src, float value)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src), 2, "sizes do not match");
  THCudaTensor *self = THCudaTensor_newContiguous(self_);
  src = THCudaTensor_newContiguous(src);
  long size = THCudaTensor_nElement(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));
  thrust::device_ptr<float> src_data(THCudaTensor_data(src));
  
  thrust::transform(src_data, src_data+size, self_data, pow_functor(value));

  THCudaTensor_freeCopyTo(self, self_);
}


struct sign_functor
{
  __device__ float operator()(const float &v) const {
    return (v > 0) - (v < 0);
  }
};


void THCudaTensor_sign(THCudaTensor *self_, THCudaTensor *src)
{
  THArgCheck(THCudaTensor_nElement(self_) == THCudaTensor_nElement(src), 2, "size do not match");

  {
    THCudaTensor *self = THCudaTensor_newContiguous(self_);
    long size = THCudaTensor_nElement(self);
    src = THCudaTensor_newContiguous(src);
    thrust::device_ptr<float> self_data(THCudaTensor_data(self));
    thrust::device_ptr<float> src_data(THCudaTensor_data(src));

    thrust::transform(src_data, src_data+size, self_data, sign_functor());

    THCudaTensor_free(src);
    THCudaTensor_freeCopyTo(self, self_);
  }
}

float THCudaTensor_meanall(THCudaTensor *self)
{
  THArgCheck(self->nDimension > 0, 1, "empty Tensor");
  return THCudaTensor_sumall(self)/THCudaTensor_nElement(self);
}

struct square_functor
{
  const float mean;

  square_functor(float mean_) : mean(mean_) {}

    __host__ __device__ float operator()(const float& x) const
  {
    return (x-mean)*(x-mean);
  }
};

float THCudaTensor_varall(THCudaTensor *self)
{
  self = THCudaTensor_newContiguous(self);
  long size = THCudaTensor_nElement(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  float mean = THCudaTensor_meanall(self);
  float result = thrust::transform_reduce(self_data, self_data+size, square_functor(mean), (float)0, thrust::plus<float>());

  result = result/(THCudaTensor_nElement(self)-1);

  THCudaTensor_free(self);
  return result;
}

float THCudaTensor_stdall(THCudaTensor *self)
{
  return sqrt(THCudaTensor_varall(self));
}

struct norm_functor
{
  const float exponent;

  norm_functor(float exponent_) : exponent(exponent_) {}

    __host__ __device__ float operator()(const float& x) const
  {
    return pow(fabs(x), exponent);
  }
};

float THCudaTensor_norm(THCudaTensor *self, float value)
{
  self = THCudaTensor_newContiguous(self);
  long size = THCudaTensor_nElement(self);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));

  float result = thrust::transform_reduce(self_data, self_data+size, norm_functor(value), (float)0, thrust::plus<float>());

  THCudaTensor_free(self);
  return pow(result, (float)1.0/value);
}

struct dist_functor
{
  const float exponent;

  dist_functor(float exponent_) : exponent(exponent_) {}

  __host__ __device__ float operator()(const float& x, const float& y) const
  {
    return pow(fabs(x-y), exponent);
  }
};

float THCudaTensor_dist(THCudaTensor *self, THCudaTensor *src, float value)
{
  self = THCudaTensor_newContiguous(self);
  long size = THCudaTensor_nElement(self);
  src = THCudaTensor_newContiguous(src);
  thrust::device_ptr<float> self_data(THCudaTensor_data(self));
  thrust::device_ptr<float> src_data(THCudaTensor_data(src));

  float result = thrust::inner_product(self_data, self_data+size, src_data, (float) 0,thrust::plus<float>(), dist_functor(value));

  THCudaTensor_free(src);
  THCudaTensor_free(self);
  
  return pow(result, (float)1.0/value);
}

void THCudaTensor_rand(THCudaTensor *r_, THLongStorage *size)
{
  THCudaTensor_resize(r_, size, NULL);
  THCudaTensor_uniform(r_, 0, 1);
}

void THCudaTensor_randn(THCudaTensor *r_, THLongStorage *size)
{
  THCudaTensor_resize(r_, size, NULL);
  THCudaTensor_normal(r_, 0, 1);
}
