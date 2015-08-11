#include <vector>

#include "caffe/layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/st_layer.hpp"

namespace caffe {

template <typename Dtype>
__global__ void SpatialTransformerForwardGPU(const int nthreads, int N, int C,
		int output_H_, int output_W_, int H, int W,
		Dtype* input_grid_data, const Dtype* U, Dtype* V) {
	
	CUDA_KERNEL_LOOP(index, nthreads) {

		const int t = index % output_W_;
		const int s = (index / output_W_) % output_H_;
		const int j = (index / (output_W_ * output_H_)) % C;
		const int i = index / (output_W_ * output_H_ * C);

		Dtype* coordinates = input_grid_data + (output_H_ * output_W_ * 2) * i;
		const int row_idx = output_W_ * s + t;

	  	const Dtype px = coordinates[row_idx * 2];
	  	const Dtype py = coordinates[row_idx * 2 + 1];

	  	const int V_offset = i * (C * output_H_ * output_W_) + j * (output_H_ * output_W_)
	  			+ s * output_W_ + t;

	  	V[V_offset] = (Dtype)0.;

	  	const Dtype x = (px + 1) / 2 * H;
	  	const Dtype y = (py + 1) / 2 * W;

	  	int m, n; Dtype w;
	  	const Dtype* pic = U + i * (C * H * W) + j * (H * W);

	  	m = floor(x); n = floor(y); w = 0;
	  	if(m >= 0 && m < H && n >= 0 && n < W) {
	  		w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));
	  		V[V_offset] += w * pic[m * W + n];
	  	}

	  	m = floor(x) + 1; n = floor(y); w = 0;
	  	if(m >= 0 && m < H && n >= 0 && n < W) {
	  		w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));
	  		V[V_offset] += w * pic[m * W + n];
	  	}

	  	m = floor(x); n = floor(y) + 1; w = 0;
	  	if(m >= 0 && m < H && n >= 0 && n < W) {
	  		w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));
	  		V[V_offset] += w * pic[m * W + n];
	  	}

	  	m = floor(x) + 1; n = floor(y) + 1; w = 0;
	  	if(m >= 0 && m < H && n >= 0 && n < W) {
	  		w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));
	  		V[V_offset] += w * pic[m * W + n];
	  	}
  }
}

template <typename Dtype>
void SpatialTransformerLayer<Dtype>::Forward_gpu(
    const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {

	const Dtype* U = bottom[0]->gpu_data();
	const Dtype* theta = bottom[1]->gpu_data();
	const Dtype* output_grid_data = output_grid->gpu_data();

	Dtype* input_grid_data = input_grid->mutable_gpu_data();
	Dtype* V = top[0]->mutable_gpu_data();

	caffe_gpu_set(input_grid->count(), (Dtype)0, input_grid_data);
	caffe_gpu_set(top[0]->count(), (Dtype)0, V);

	// compute out input_grid_data
	for(int i = 0; i < N; ++i) {
		caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasTrans, output_H_ * output_W_, 2, 3, (Dtype)1.,
				output_grid_data, theta + 6 * i, (Dtype)0.,
				input_grid_data + (output_H_ * output_W_ * 2) * i);
	}

	const int nthreads = N * C * output_H_ * output_W_;

	SpatialTransformerForwardGPU<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
	      CAFFE_CUDA_NUM_THREADS>>>(nthreads, N, C, output_H_, output_W_, H, W, input_grid_data, U, V);

}

template <typename Dtype>
__global__ void SpatialTransformerBackwardGPU(const int nthreads, int C,
		int output_H_, int output_W_, int H, int W,
		const Dtype* input_grid_data, const Dtype* dV_array, const Dtype* U_array,  
		Dtype* dU_tmp_diff, Dtype* dTheta_tmp_diff) {
	
	CUDA_KERNEL_LOOP(index, nthreads) {

		const int t = index % output_W_;
		const int s = (index / output_W_) % output_H_;
		const int j = (index / (output_W_ * output_H_)) % C;
		const int i = index / (output_W_ * output_H_ * C);

		const Dtype* coordinates = input_grid_data + (output_H_ * output_W_ * 2) * i;

		const int row_idx = output_W_ * s + t;

		const Dtype px = coordinates[row_idx * 2];
		const Dtype py = coordinates[row_idx * 2 + 1];
		
		Dtype delta_dpx = (Dtype)0.;
		Dtype delta_dpy = (Dtype)0.;

		const Dtype x = (px + 1) / 2 * H;
		const Dtype y = (py + 1) / 2 * W;
		const int dV_offset = i * (C * output_H_ * output_W_) + j * (output_H_ * output_W_)
				+ s * output_W_ + t;
		const int dU_tmp_diff_offset = i * (C * H * W) + j * (H * W);
		const Dtype dV = dV_array[dV_offset];

		int m, n; Dtype w;
		const Dtype* U = U_array + i * (C * H * W) + j * (H * W);

		// left-bottom neighbor
		m = floor(x); n = floor(y); w = 0;
		if(m >= 0 && m < H && n >= 0 && n < W) {
			w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));

			int tmp_offset = (dU_tmp_diff_offset + m * W + n) * (output_H_ * output_W_) + row_idx;
			dU_tmp_diff[tmp_offset] += w * dV;

			if(abs(x - m) < 1) {
				if(m >= x) {
					delta_dpx += fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				} else {
					delta_dpx -= fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				}
			}

			if(abs(y - n) < 1) {
				if(n >= y) {
					delta_dpy += fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				} else {
					delta_dpy -= fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				}
			}
		}
		
		// left-top neighbor
		m = floor(x); n = floor(y) + 1; w = 0;
		if(m >= 0 && m < H && n >= 0 && n < W) {
			w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));

			int tmp_offset = (dU_tmp_diff_offset + m * W + n) * (output_H_ * output_W_) + row_idx;
			dU_tmp_diff[tmp_offset] += w * dV;

			if(abs(x - m) < 1) {
				if(m >= x) {
					delta_dpx += fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				} else {
					delta_dpx -= fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				}
			}

			if(abs(y - n) < 1) {
				if(n >= y) {
					delta_dpy += fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				} else {
					delta_dpy -= fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				}
			}
		}

		// right-bottom neighbor
		m = floor(x) + 1; n = floor(y); w = 0;
		if(m >= 0 && m < H && n >= 0 && n < W) {
			w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));

			int tmp_offset = (dU_tmp_diff_offset + m * W + n) * (output_H_ * output_W_) + row_idx;
			dU_tmp_diff[tmp_offset] += w * dV;

			if(abs(x - m) < 1) {
				if(m >= x) {
					delta_dpx += fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				} else {
					delta_dpx -= fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				}
			}

			if(abs(y - n) < 1) {
				if(n >= y) {
					delta_dpy += fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				} else {
					delta_dpy -= fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				}
			}
		}
		
		// right-top neighbor
		m = floor(x) + 1; n = floor(y) + 1; w = 0;
		if(m >= 0 && m < H && n >= 0 && n < W) {
			w = fmaxf(0, 1 - abs(x - m)) * fmaxf(0, 1 - abs(y - n));

			int tmp_offset = (dU_tmp_diff_offset + m * W + n) * (output_H_ * output_W_) + row_idx;
			dU_tmp_diff[tmp_offset] += w * dV;

			if(abs(x - m) < 1) {
				if(m >= x) {
					delta_dpx += fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				} else {
					delta_dpx -= fmaxf(0, 1 - abs(y - n)) * U[m * W + n] * dV * H / 2;
				}
			}

			if(abs(y - n) < 1) {
				if(n >= y) {
					delta_dpy += fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				} else {
					delta_dpy -= fmaxf(0, 1 - abs(x - m)) * U[m * W + n] * dV * W / 2;
				}
			}
		}
		
		int idx = j * (output_H_ * output_W_) + s * output_W_ + t;
		
		dTheta_tmp_diff[(6 * i) * (output_H_ * output_W_ * C) + idx] += delta_dpx * (s * 1.0 / output_H_ * 2 - 1);
		dTheta_tmp_diff[(6 * i + 1) * (output_H_ * output_W_ * C) + idx] += delta_dpx * (t * 1.0 / output_W_ * 2 - 1);
		dTheta_tmp_diff[(6 * i + 2) * (output_H_ * output_W_ * C) + idx] += delta_dpx;
		dTheta_tmp_diff[(6 * i + 3) * (output_H_ * output_W_ * C) + idx] += delta_dpy * (s * 1.0 / output_H_ * 2 - 1);
		dTheta_tmp_diff[(6 * i + 4) * (output_H_ * output_W_ * C) + idx] += delta_dpy * (t * 1.0 / output_W_ * 2 - 1);
		dTheta_tmp_diff[(6 * i + 5) * (output_H_ * output_W_ * C) + idx] += delta_dpy;
	}
}

template <typename Dtype>
void SpatialTransformerLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {

	const Dtype* dV = top[0]->gpu_diff();
	const Dtype* input_grid_data = input_grid->gpu_data();
	const Dtype* U = bottom[0]->gpu_data();

	Dtype* dU = bottom[0]->mutable_gpu_diff();
	Dtype* dTheta = bottom[1]->mutable_gpu_diff();
	Dtype* dU_tmp_diff = dU_tmp->mutable_gpu_diff();
	Dtype* dTheta_tmp_diff = dTheta_tmp->mutable_gpu_diff();

	caffe_gpu_set(dU_tmp->count(), (Dtype)0., dU_tmp_diff);
	caffe_gpu_set(dTheta_tmp->count(), (Dtype)0., dTheta_tmp_diff);

	const int nthreads = N * C * output_H_ * output_W_;

	SpatialTransformerBackwardGPU<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
			CAFFE_CUDA_NUM_THREADS>>>(nthreads, C, output_H_, output_W_, H, W, input_grid_data,
					dV, U, dU_tmp_diff, dTheta_tmp_diff);
	
	Dtype* all_ones_1_data = all_ones_1->mutable_gpu_data();
	caffe_gpu_set(all_ones_1->count(), (Dtype)1., all_ones_1_data);

	caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, bottom[0]->count(), 1, output_H_ * output_W_,
			(Dtype)1., dU_tmp_diff, all_ones_1_data, (Dtype)0., dU);
	
	Dtype* all_ones_2_data = all_ones_2->mutable_gpu_data();
	caffe_gpu_set(all_ones_2->count(), (Dtype)1., all_ones_2_data);
	
	caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, bottom[1]->count(), 1, output_H_ * output_W_ * C, 
			(Dtype)1., dTheta_tmp_diff, all_ones_2_data, (Dtype)0., dTheta);
}

INSTANTIATE_LAYER_GPU_FUNCS(SpatialTransformerLayer);

}	// namespace caffe
