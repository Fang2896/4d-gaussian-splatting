/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */
#include <iostream>
#include "forward.h"
#include "auxiliary.h"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

// Forward method for converting the input spherical harmonics
// coefficients of each Gaussian to a simple RGB color.
__device__ glm::vec3 computeColorFromSH(int idx, int deg, int max_coeffs, const glm::vec3* means, glm::vec3 campos, const float* shs, bool* clamped)
{
	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 pos = means[idx];
	glm::vec3 dir = pos - campos;
	dir = dir / glm::length(dir);

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;
	glm::vec3 result = SH_C0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2)
			{
				result = result +
					SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
					SH_C3[1] * xy * z * sh[10] +
					SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
					SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
					SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
					SH_C3[5] * z * (xx - yy) * sh[14] +
					SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
	return glm::max(result, 0.0f);
}

__device__ glm::vec3 computeColorFromSH_4D(int idx, int deg, int deg_t, int max_coeffs, const glm::vec3* means,
		 glm::vec3 campos, const float* shs, bool* clamped, const float* ts, const float timestamp, const float time_duration)
{
	// The implementation is loosely based on code for
	// "Differentiable Point-Based Radiance Fields for
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 pos = means[idx];
	glm::vec3 dir = pos - campos;
	dir = dir / glm::length(dir);

	const float dir_t = ts[idx]-timestamp;

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;

	float l0m0=SH_C0;
	glm::vec3 result = l0m0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;

		float l1m1 = -1 * SH_C1 * y;
		float l1m0 = SH_C1 * z;
		float l1p1 = -1 * SH_C1 * x;

		result += 
			l1m1 * sh[1] +
			l1m0 * sh[2] +
			l1p1 * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;

			float l2m2 = SH_C2[0] * xy;
            float l2m1 = SH_C2[1] * yz;
            float l2m0 = SH_C2[2] * (2.0 * zz - xx - yy);
            float l2p1 = SH_C2[3] * xz;
            float l2p2 = SH_C2[4] * (xx - yy);

			result +=
                l2m2 * sh[4] +
                l2m1 * sh[5] +
                l2m0 * sh[6] +
                l2p1 * sh[7] +
                l2p2 * sh[8];

			if (deg > 2)
			{
				float l3m3 = SH_C3[0] * y * (3 * xx - yy);
                float l3m2 = SH_C3[1] * xy * z;
                float l3m1 = SH_C3[2] * y * (4 * zz - xx - yy);
                float l3m0 = SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy);
                float l3p1 = SH_C3[4] * x * (4 * zz - xx - yy);
                float l3p2 = SH_C3[5] * z * (xx - yy);
                float l3p3 = SH_C3[6] * x * (xx - 3 * yy);

				result +=
					l3m3 * sh[9] +
					l3m2 * sh[10] +
					l3m1 * sh[11] +
					l3m0 * sh[12] +
					l3p1 * sh[13] +
					l3p2 * sh[14] +
					l3p3 * sh[15];

				if (deg_t > 0){
					float t1 = cos(2 * MY_PI * dir_t / time_duration);

					result += t1 * (l0m0 * sh[16] +
						l1m1 * sh[17] +
						l1m0 * sh[18] +
						l1p1 * sh[19] + 
						l2m2 * sh[20] +
						l2m1 * sh[21] +
						l2m0 * sh[22] +
						l2p1 * sh[23] +
						l2p2 * sh[24] + 
						l3m3 * sh[25] +
						l3m2 * sh[26] +
						l3m1 * sh[27] +
						l3m0 * sh[28] +
						l3p1 * sh[29] +
						l3p2 * sh[30] +
						l3p3 * sh[31]);

					if (deg_t > 1){
						float t2 = cos(2 * MY_PI * dir_t * 2 / time_duration);

						result += t2 * (l0m0 * sh[32] +
							l1m1 * sh[33] +
							l1m0 * sh[34] +
							l1p1 * sh[35] + 
							l2m2 * sh[36] +
							l2m1 * sh[37] +
							l2m0 * sh[38] +
							l2p1 * sh[39] +
							l2p2 * sh[40] + 
							l3m3 * sh[41] +
							l3m2 * sh[42] +
							l3m1 * sh[43] +
							l3m0 * sh[44] +
							l3p1 * sh[45] +
							l3p2 * sh[46] +
							l3p3 * sh[47]);
					}

				}
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
	return glm::max(result, 0.0f);
}

// Forward version of 2D covariance matrix computation
__device__ float3 computeCov2D(const float3& mean, float focal_x, float focal_y, float tan_fovx, float tan_fovy, const float* cov3D, const float* viewmatrix)
{
	// The following models the steps outlined by equations 29
	// and 31 in "EWA Splatting" (Zwicker et al., 2002). 
	// Additionally considers aspect / scaling of viewport.
	// Transposes used to account for row-/column-major conventions.
	float3 t = transformPoint4x3(mean, viewmatrix);

	const float limx = 1.3f * tan_fovx;
	const float limy = 1.3f * tan_fovy;
	const float txtz = t.x / t.z;
	const float tytz = t.y / t.z;
	t.x = min(limx, max(-limx, txtz)) * t.z;
	t.y = min(limy, max(-limy, tytz)) * t.z;

	glm::mat3 J = glm::mat3(
		focal_x / t.z, 0.0f, -(focal_x * t.x) / (t.z * t.z),
		0.0f, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z),
		0, 0, 0);

	glm::mat3 W = glm::mat3(
		viewmatrix[0], viewmatrix[4], viewmatrix[8],
		viewmatrix[1], viewmatrix[5], viewmatrix[9],
		viewmatrix[2], viewmatrix[6], viewmatrix[10]);

	glm::mat3 T = W * J;

	glm::mat3 Vrk = glm::mat3(
		cov3D[0], cov3D[1], cov3D[2],
		cov3D[1], cov3D[3], cov3D[4],
		cov3D[2], cov3D[4], cov3D[5]);

	glm::mat3 cov = glm::transpose(T) * glm::transpose(Vrk) * T;

	// Apply low-pass filter: every Gaussian should be at least
	// one pixel wide/high. Discard 3rd row and column.
	cov[0][0] += 0.3f;
	cov[1][1] += 0.3f;
	return { float(cov[0][0]), float(cov[0][1]), float(cov[1][1]) };
}

// Forward method for converting scale and rotation properties of each
// Gaussian to a 3D covariance matrix in world space. Also takes care
// of quaternion normalization.
__device__ void computeCov3D(const glm::vec3 scale, float mod, const glm::vec4 rot, float* cov3D)
{
	// Create scaling matrix
	glm::mat3 S = glm::mat3(1.0f);
	S[0][0] = mod * scale.x;
	S[1][1] = mod * scale.y;
	S[2][2] = mod * scale.z;

	// Normalize quaternion to get valid rotation
	glm::vec4 q = rot;// / glm::length(rot);
	float r = q.x;
	float x = q.y;
	float y = q.z;
	float z = q.w;

	// Compute rotation matrix from quaternion
	glm::mat3 R = glm::mat3(
		1.f - 2.f * (y * y + z * z), 2.f * (x * y - r * z), 2.f * (x * z + r * y),
		2.f * (x * y + r * z), 1.f - 2.f * (x * x + z * z), 2.f * (y * z - r * x),
		2.f * (x * z - r * y), 2.f * (y * z + r * x), 1.f - 2.f * (x * x + y * y)
	);

	glm::mat3 M = S * R;

	// Compute 3D world covariance matrix Sigma
	glm::mat3 Sigma = glm::transpose(M) * M;

	// Covariance is symmetric, only store upper right
	cov3D[0] = Sigma[0][0];
	cov3D[1] = Sigma[0][1];
	cov3D[2] = Sigma[0][2];
	cov3D[3] = Sigma[1][1];
	cov3D[4] = Sigma[1][2];
	cov3D[5] = Sigma[2][2];
}


// 额外参数支持条件高斯模型和时间动态效果。
// 处理了时间维度，通过计算时间缩放和动态调整原点位置来处理时间相关的变化
__device__ void computeCov3D_conditional(const glm::vec3 scale, const float scale_t, float mod,
		const glm::vec4 rot, const glm::vec4 rot_r, float* cov3D, float3& p_orig, float3& flow_3d,
		float t, const float timestamp, int idx, bool& mask, float& opacity)
{
	// Create scaling matrix
	float dt=timestamp-t;
	glm::mat4 S = glm::mat4(1.0f);
	S[0][0] = mod * scale.x;
	S[1][1] = mod * scale.y;
	S[2][2] = mod * scale.z;
	S[3][3] = mod * scale_t;

	float a = rot.x;
	float b = rot.y;
	float c = rot.z;
	float d = rot.w;

	float p = rot_r.x;
	float q = rot_r.y;
	float r = rot_r.z;
	float s = rot_r.w;

	glm::mat4 M_l = glm::mat4(
		a, -b, -c, -d,
		b, a,-d, c,
		c, d, a,-b,
		d,-c, b, a
	);

	glm::mat4 M_r = glm::mat4(
		p, q, r, s,
		-q, p,-s, r,
		-r, s, p,-q,
		-s,-r, q, p
	);
	// glm stores in column major
	glm::mat4 R = M_r * M_l;
	glm::mat4 M = S * R;
	glm::mat4 Sigma = glm::transpose(M) * M;
	float cov_t = Sigma[3][3];
	float marginal_t = __expf(-0.5*dt*dt/cov_t);
	mask = marginal_t > 0.05;	// 参考论文，会剔除掉t高斯分布中小于0.05的
	if (!mask) return;
	// 核心代码！说明这篇文章的所谓的动态，其实只不过是t高斯边缘分布的动态改变各个3DG的透明度罢了！
	opacity*=marginal_t;	
	glm::mat3 cov11 = glm::mat3(Sigma);
	// Σ_{1:3,4}
	glm::vec3 cov12 = glm::vec3(Sigma[0][3],Sigma[1][3],Sigma[2][3]);
	// 参考论文公式Σ_{xyz|t}:
	// = Σ_{1:3,1:3} - Σ_{1:3,4} Σ^{-1}_{4,4} Σ_{1:3,4} （注意中间这个就是个常数）
	glm::mat3 cov3D_condition = cov11 - glm::outerProduct(cov12, cov12) / cov_t;

	// Covariance is symmetric, only store upper right
	cov3D[0] = cov3D_condition[0][0];
	cov3D[1] = cov3D_condition[0][1];
	cov3D[2] = cov3D_condition[0][2];
	cov3D[3] = cov3D_condition[1][1];
	cov3D[4] = cov3D_condition[1][2];
	cov3D[5] = cov3D_condition[2][2];

	// 这个就是相应的条件均值 μ_{xyz|t} ，但是这个为什么是dt，而不是 t - μ_t ?
	// 这个dt 就是 timestamp-t ，所以按照论文来说，这个timestamp才是t，这个t才是 μt ？
    glm::vec3 delta_mean = cov12 / cov_t * dt;
	p_orig.x+=delta_mean.x;
	p_orig.y+=delta_mean.y;
	p_orig.z+=delta_mean.z;

	flow_3d.x = delta_mean.x;
	flow_3d.y = delta_mean.y;
	flow_3d.z = delta_mean.z;
}

// Perform initial steps for each Gaussian prior to rasterization.
template<int C>
__global__ void preprocessCUDA(int P, int D, int D_t, int M,
	const float* orig_points,
	const float* ts,
	const glm::vec3* scales,
	const float* scales_t,
	const float scale_modifier,
	const glm::vec4* rotations,
	const glm::vec4* rotations_r,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const float timestamp,
	const float time_duration,
	const bool rot_4d, const int gaussian_dim, const bool force_sh_3d,
	const int W, int H,
	const float tan_fovx, float tan_fovy,
	const float focal_x, float focal_y,
	int* radii,
	float2* points_xy_image,
	float2* flow_xy_image,		// 这里加了一个flow的，表示该像素点的flow！
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Initialize radius and touched tiles to 0. If this isn't changed,
	// this Gaussian will not be processed further.
	radii[idx] = 0;
	tiles_touched[idx] = 0;

	// // Perform near culling, quit if outside.
	// float3 p_view;
	// if (!in_frustum(idx, orig_points, viewmatrix, projmatrix, prefiltered, p_view))
	// 	return;

	// Transform point by projecting
	float3 p_orig = { orig_points[3 * idx], orig_points[3 * idx + 1], orig_points[3 * idx + 2] };
	float3 flow_3d = {0.0f, 0.0f, 0.0f};
	float opacity = opacities[idx];

	// If 3D covariance matrix is precomputed, use it, otherwise compute
	// from scaling and rotation parameters.
	const float* cov3D;	// 可以改变指针指向，但不能改变指向的值
	if (cov3D_precomp != nullptr)
	{
		cov3D = cov3D_precomp + idx * 6;
	}
	else if (rot_4d) // gaussian_dim == 4 && rot_4d
	{
		bool time_mask=true;
		computeCov3D_conditional(scales[idx], scales_t[idx], scale_modifier,
			rotations[idx], rotations_r[idx], cov3Ds + idx * 6, 
			p_orig, flow_3d,	// 关键的两个
			ts[idx], timestamp, idx, time_mask, opacity);
		if (!time_mask) return;
		cov3D = cov3Ds + idx * 6;
	}
	else
	{
		// 这个就是rotation 没有加上时间维度的。
		// 也就是独立一个t的
		computeCov3D(scales[idx], scale_modifier, rotations[idx], cov3Ds + idx * 6);
		cov3D = cov3Ds + idx * 6;
		if (gaussian_dim == 4){  // no rot_4d
            float dt = ts[idx]-timestamp;
            float sigma = scales_t[idx] * scale_modifier;
		    float marginal_t = __expf(-0.5*dt*dt/sigma);
		    if (marginal_t <= 0.05) return;
		    opacity *= marginal_t;
		}
	}

	// Perform near culling, quit if outside.
	// 这个同时会计算p_view
	float3 p_view;
	if (!in_frustum(p_orig, viewmatrix, projmatrix, prefiltered, p_view))
		return;

	// Transform point by projecting
	float4 p_hom = transformPoint4x4(p_orig, projmatrix);
	float p_w = 1.0f / (p_hom.w + 0.0000001f);	// 齐次化坐标
	float3 p_proj = { p_hom.x * p_w, p_hom.y * p_w, p_hom.z * p_w };

	// 将3d空间的绝对flow转换到摄像机坐标系下，然后转到2D平面下
	float3 flow_view = transformVec4x3(flow_3d, viewmatrix);
	float2 flow_image = {0.0f, 0.0f};
	flow_image.x = flow_view.x * focal_x;
	flow_image.y = flow_view.y * focal_y;

	// Compute 2D screen-space covariance matrix
	float3 cov = computeCov2D(p_orig, focal_x, focal_y, tan_fovx, tan_fovy, cov3D, viewmatrix);

	// Invert covariance (EWA algorithm)
	float det = (cov.x * cov.z - cov.y * cov.y);
	if (det == 0.0f)
		return;
	float det_inv = 1.f / det;
	float3 conic = { cov.z * det_inv, -cov.y * det_inv, cov.x * det_inv };

	// Compute extent in screen space (by finding eigenvalues of
	// 2D covariance matrix). Use extent to compute a bounding rectangle
	// of screen-space tiles that this Gaussian overlaps with. Quit if
	// rectangle covers 0 tiles.
	float mid = 0.5f * (cov.x + cov.z);
	float lambda1 = mid + sqrt(max(0.1f, mid * mid - det));
	float lambda2 = mid - sqrt(max(0.1f, mid * mid - det));
	float my_radius = ceil(3.f * sqrt(max(lambda1, lambda2)));	// 椭圆特征值的最大值
	float2 point_image = { ndc2Pix(p_proj.x, W), ndc2Pix(p_proj.y, H) };
	uint2 rect_min, rect_max;
	getRect(point_image, my_radius, rect_min, rect_max, grid);
	if ((rect_max.x - rect_min.x) * (rect_max.y - rect_min.y) == 0 || ((int)my_radius <= 0.4))
		return;

	// If colors have been precomputed, use them, otherwise convert
	// spherical harmonics coefficients to RGB color.
	if (colors_precomp == nullptr)
	{
		glm::vec3 result;
		if (gaussian_dim == 3 || force_sh_3d){
			result = computeColorFromSH(idx, D, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped);
		}else{
			// 核心函数
			result = computeColorFromSH_4D(idx, D, D_t, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped, ts, timestamp, time_duration);
		}
		rgb[idx * C + 0] = result.x;
		rgb[idx * C + 1] = result.y;
		rgb[idx * C + 2] = result.z;
	}

	// Store some useful helper data for the next steps.
	depths[idx] = p_view.z;
	radii[idx] = my_radius;
	points_xy_image[idx] = point_image;
	flow_xy_image[idx] = flow_image;	// 注意这里加上了flow
	// Inverse 2D covariance and opacity neatly pack into one float4
	conic_opacity[idx] = { conic.x, conic.y, conic.z, opacity };
	tiles_touched[idx] = (rect_max.y - rect_min.y) * (rect_max.x - rect_min.x);
}

// Main rasterization method. Collaboratively works on one tile per
// block, each thread treats one pixel. Alternates between fetching 
// and rasterizing data.
template <uint32_t CHANNELS>
__global__ void __launch_bounds__(BLOCK_X * BLOCK_Y)
renderCUDA(
	const uint2* __restrict__ ranges,
	const uint32_t* __restrict__ point_list,
	int W, int H,
	const float2* __restrict__ points_xy_image,
	const float2* __restrict__ flow_xy_image,
	const float* __restrict__ features,
	const float* __restrict__ flows,
	const float* __restrict__ depths,
	const float4* __restrict__ conic_opacity,
	float* __restrict__ final_T,
	uint32_t* __restrict__ n_contrib,
	const float* __restrict__ bg_color,
	float* __restrict__ out_color,
	float* __restrict__ out_flow,
	float* __restrict__ out_depth)
{
	// Identify current tile and associated min/max pixel range.
	auto block = cg::this_thread_block();
	uint32_t horizontal_blocks = (W + BLOCK_X - 1) / BLOCK_X;
	uint2 pix_min = { block.group_index().x * BLOCK_X, block.group_index().y * BLOCK_Y };
	uint2 pix_max = { min(pix_min.x + BLOCK_X, W), min(pix_min.y + BLOCK_Y , H) };
	uint2 pix = { pix_min.x + block.thread_index().x, pix_min.y + block.thread_index().y };
	uint32_t pix_id = W * pix.y + pix.x;
	float2 pixf = { (float)pix.x, (float)pix.y };

	// Check if this thread is associated with a valid pixel or outside.
	bool inside = pix.x < W&& pix.y < H;
	// Done threads can help with fetching, but don't rasterize
	bool done = !inside;

	// Load start/end range of IDs to process in bit sorted list.
	uint2 range = ranges[block.group_index().y * horizontal_blocks + block.group_index().x];
	const int rounds = ((range.y - range.x + BLOCK_SIZE - 1) / BLOCK_SIZE);
	int toDo = range.y - range.x;

	// Allocate storage for batches of collectively fetched data.
	// 同一线程块之间的所有线程共享
	__shared__ int collected_id[BLOCK_SIZE];
	__shared__ float2 collected_xy[BLOCK_SIZE];
	__shared__ float2 collected_flow_xy[BLOCK_SIZE];
	__shared__ float4 collected_conic_opacity[BLOCK_SIZE];

	// Initialize helper variables
	float T = 1.0f;
	uint32_t contributor = 0;
	uint32_t last_contributor = 0;
	float C[CHANNELS] = { 0 };
	float Flow[2] = { 0 };
	float D = { 0 };

	// Iterate over batches until all done or range is complete
	for (int i = 0; i < rounds; i++, toDo -= BLOCK_SIZE)
	{
		// End if entire block votes that it is done rasterizing
		// 同一线程块的所有线程之间进行同步。
		int num_done = __syncthreads_count(done);
		if (num_done == BLOCK_SIZE)
			break;

		// Collectively fetch per-Gaussian data from global to shared
		int progress = i * BLOCK_SIZE + block.thread_rank();
		if (range.x + progress < range.y)
		{
			int coll_id = point_list[range.x + progress];
			collected_id[block.thread_rank()] = coll_id;
			collected_xy[block.thread_rank()] = points_xy_image[coll_id];
			collected_flow_xy[block.thread_rank()] = flow_xy_image[coll_id];
			collected_conic_opacity[block.thread_rank()] = conic_opacity[coll_id];
		}

		// 同步同一线程块中的所有线程
		block.sync();

		// Iterate over current batch
		for (int j = 0; !done && j < min(BLOCK_SIZE, toDo); j++)
		{
			// Keep track of current position in range
			contributor++;

			// Resample using conic matrix (cf. "Surface 
			// Splatting" by Zwicker et al., 2001)
			float2 xy = collected_xy[j];
			float2 flow_xy = collected_flow_xy[j];
			float2 d = { xy.x - pixf.x, xy.y - pixf.y };
			float4 con_o = collected_conic_opacity[j];
			float power = -0.5f * (con_o.x * d.x * d.x + con_o.z * d.y * d.y) - con_o.y * d.x * d.y;
			if (power > 0.0f)
				continue;

			// Eq. (2) from 3D Gaussian splatting paper.
			// Obtain alpha by multiplying with Gaussian opacity
			// and its exponential falloff from mean.
			// Avoid numerical instabilities (see paper appendix). 
			float alpha = min(0.99f, con_o.w * exp(power));
			if (alpha < 1.0f / 255.0f)
				continue;
			float test_T = T * (1 - alpha);
			if (test_T < 0.0001f)
			{
				done = true;
				continue;
			}

			// Eq. (3) from 3D Gaussian splatting paper.
			// 这个feature就是colors
			for (int ch = 0; ch < CHANNELS; ch++)
				C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha * T;
			// for (int ch = 0; ch < 2; ch++)
			// 	Flow[ch] += flows[collected_id[j] * 2 + ch] * alpha * T;
			Flow[0] += flow_xy.x * alpha * T;
			Flow[1] += flow_xy.y * alpha * T;

			D += depths[collected_id[j]] * alpha * T;

			T = test_T;

			// Keep track of last range entry to update this
			// pixel.
			last_contributor = contributor;
		}
	}

	// All threads that treat valid pixel write out their final
	// rendering data to the frame and auxiliary buffers.
	if (inside)
	{
		final_T[pix_id] = T;
		n_contrib[pix_id] = last_contributor;
		for (int ch = 0; ch < CHANNELS; ch++)
			out_color[ch * H * W + pix_id] = C[ch] + T * bg_color[ch];
		for (int ch = 0; ch < 2; ch++)
			out_flow[ch * H * W + pix_id] = Flow[ch];
		out_depth[pix_id] = D;
	}
}

void FORWARD::render(
	const dim3 grid, dim3 block,
	const uint2* ranges,
	const uint32_t* point_list,
	int W, int H,
	const float2* means2D,
	const float2* flow2D,
	const float* colors,
	const float* flows,
	const float* depths,
	const float4* conic_opacity,
	float* final_T,
	uint32_t* n_contrib,
	const float* bg_color,
	float* out_color,
	float* out_flow,
	float* out_depth)
{
	// 每个线程都会执行一次
	renderCUDA<NUM_CHANNELS> << <grid, block >> > (
		ranges,
		point_list,
		W, H,
		means2D,
		flow2D,
		colors,
		flows,
		depths,
		conic_opacity,
		final_T,
		n_contrib,
		bg_color,
		out_color,
		out_flow,
		out_depth);
}

void FORWARD::preprocess(int P, int D, int D_t, int M,
	const float* means3D,
	const float* ts,
	const glm::vec3* scales,
	const float* scales_t,
	const float scale_modifier,
	const glm::vec4* rotations,
	const glm::vec4* rotations_r,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const float timestamp,
	const float time_duration,
	const bool rot_4d, const int gaussian_dim, const bool force_sh_3d,
	const int W, int H,
	const float focal_x, float focal_y,
	const float tan_fovx, float tan_fovy,
	int* radii,
	float2* means2D,
	float2* flow2D,	// 这个是多加的
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered)
{
	preprocessCUDA<NUM_CHANNELS> << <(P + 255) / 256, 256 >> > (
		P, D, D_t, M,
		means3D,
		ts,
		scales,
		scales_t,
		scale_modifier,
		rotations,
		rotations_r,
		opacities,
		shs,
		clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix,
		projmatrix,
		cam_pos,
		timestamp,
		time_duration,
		rot_4d, gaussian_dim, force_sh_3d,
		W, H,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		means2D,
		flow2D,
		depths,
		cov3Ds,
		rgb,
		conic_opacity,
		grid,
		tiles_touched,
		prefiltered
		);
}