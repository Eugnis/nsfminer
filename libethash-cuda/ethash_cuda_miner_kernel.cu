/*
* Genoil's CUDA mining kernel for Ethereum
* based on Tim Hughes' opencl kernel.
* thanks to sp_, trpuvot, djm34, cbuchner for things i took from ccminer.
*/

#include "ethash_cuda_miner_kernel.h"
#include "ethash_cuda_miner_kernel_globals.h"
#include "cuda_helper.h"

#include "keccak.cuh"
#include "fnv.cuh"

#define ACCESSES 64
#define THREADS_PER_HASH (128 / 16)

__device__ uint64_t compute_hash_shuffle(
	uint64_t nonce
	)
{
	// sha3_512(header .. nonce)
	uint2 state[25];

	state[4] = vectorize(nonce);

	keccak_f1600_init(state);

	// Threads work together in this phase in groups of 8.
	const int thread_id = threadIdx.x &  (THREADS_PER_HASH - 1);
	const int start_lane = threadIdx.x & ~(THREADS_PER_HASH - 1);
	const int mix_idx = thread_id & 3;

	uint4 mix;
	uint2 shuffle[8];

	for (int i = 0; i < THREADS_PER_HASH; i++)
	{
		// share init among threads
		for (int j = 0; j < 8; j++) {
			shuffle[j].x = __shfl(state[j].x, i, THREADS_PER_HASH);
			shuffle[j].y = __shfl(state[j].y, i, THREADS_PER_HASH);
		}

		// ugly but avoids local reads/writes
		if (mix_idx < 2) {
			if (mix_idx == 0)
				mix = vectorize2(shuffle[0], shuffle[1]);
			else
				mix = vectorize2(shuffle[2], shuffle[3]);
		}
		else  {
			if (mix_idx == 2)
				mix = vectorize2(shuffle[4], shuffle[5]);
			else
				mix = vectorize2(shuffle[6], shuffle[7]);
		}

		uint32_t init0 = __shfl(shuffle[0].x, start_lane);

		for (uint32_t a = 0; a < ACCESSES; a += 4)
		{
			int t = ((a >> 2) & (THREADS_PER_HASH - 1));

			for (uint32_t b = 0; b < 4; b++)
			{
				if (thread_id == t)
				{
					shuffle[0].x = fnv(init0 ^ (a + b), ((uint32_t *)&mix)[b]) % d_dag_size;
				}
				shuffle[0].x = __shfl(shuffle[0].x, t, THREADS_PER_HASH);

				mix = fnv4(mix, (&d_dag[shuffle[0].x])->uint4s[thread_id]);
			}
		}

		uint32_t thread_mix = fnv_reduce(mix);

		// update mix accross threads

		shuffle[0].x = __shfl(thread_mix, 0, THREADS_PER_HASH);
		shuffle[0].y = __shfl(thread_mix, 1, THREADS_PER_HASH);
		shuffle[1].x = __shfl(thread_mix, 2, THREADS_PER_HASH);
		shuffle[1].y = __shfl(thread_mix, 3, THREADS_PER_HASH);
		shuffle[2].x = __shfl(thread_mix, 4, THREADS_PER_HASH);
		shuffle[2].y = __shfl(thread_mix, 5, THREADS_PER_HASH);
		shuffle[3].x = __shfl(thread_mix, 6, THREADS_PER_HASH);
		shuffle[3].y = __shfl(thread_mix, 7, THREADS_PER_HASH);

		if (i == thread_id) {
			//move mix into state:
			state[8] = shuffle[0];
			state[9] = shuffle[1];
			state[10] = shuffle[2];
			state[11] = shuffle[3];
		}
	}

	// keccak_256(keccak_512(header..nonce) .. mix);
	return keccak_f1600_final(state);
}

__global__ void 
__launch_bounds__(896, 1)
ethash_search(
	volatile uint32_t* g_output,
	uint64_t start_nonce
	)
{
	uint32_t const gid = blockIdx.x * blockDim.x + threadIdx.x;	
	uint64_t hash = compute_hash_shuffle(start_nonce + gid);
	if (cuda_swab64(hash) > d_target) return;
	uint32_t index = atomicInc(const_cast<uint32_t*>(g_output), SEARCH_RESULT_BUFFER_SIZE - 1) + 1;
	g_output[index] = gid;
	__threadfence_system();
}

void run_ethash_search(
	uint32_t blocks,
	uint32_t threads,
	cudaStream_t stream,
	volatile uint32_t* g_output,
	uint64_t start_nonce
)
{
	ethash_search <<<blocks, threads, 0, stream >>>(g_output, start_nonce);
	CUDA_SAFE_CALL(cudaGetLastError());
}

void set_constants(
	hash128_t* _dag,
	uint32_t _dag_size
	)
{
	CUDA_SAFE_CALL(cudaMemcpyToSymbol(d_dag, &_dag, sizeof(hash128_t *)));
	CUDA_SAFE_CALL(cudaMemcpyToSymbol(d_dag_size, &_dag_size, sizeof(uint32_t)));
}

void set_header(
	hash32_t _header
	)
{
	CUDA_SAFE_CALL(cudaMemcpyToSymbol(d_header, &_header, sizeof(hash32_t)));
}

void set_target(
	uint64_t _target
	)
{
	CUDA_SAFE_CALL(cudaMemcpyToSymbol(d_target, &_target, sizeof(uint64_t)));
}