#include <device_memory.hpp>
#include <device_types.hpp>
#include <device_utils.cuh>
#include <safe_call.hpp>
//TODO:volume fusion
namespace kf
{
namespace device
{
    using namespace cv::cuda;
    __global__ void kernal_resetVolume(Volume vpointer)
    {
        int x = threadIdx.x + blockIdx.x * blockDim.x;
        int y = threadIdx.y + blockIdx.y * blockDim.y;

        Volume::elem_type *beg = vpointer(x, y);
        Volume::elem_type *end = beg + vpointer.znumber * vpointer.dims.z;

        for(Volume::elem_type* pos = beg; pos != end; pos = vpointer.zstep(pos))
        {
            set_voxel_tsdf(*pos, 0.f);
            set_voxel_weight(*pos, 0);
            set_voxel_color(*pos, make_uchar3(0,0,0));
        }
     } 
       void resetVolume(Volume& vpointer)
       {
        const dim3 blocks(32, 8);
        const dim3 grids(32,32);
        kernal_resetVolume << <grids, blocks >> > (vpointer);
        cudaSafeCall (cudaGetLastError());
       }
       //integrate
       struct tsdfhelper
       {
           const Intrs intr;
           const PoseT pose;
           Volume vpointer;
           tsdfhelper(const Intrs &proj_, const PoseT &pose_,const Volume& vpointer_):
           intr(proj_),pose(pose_),vpointer(vpointer_){};
           __device__ void operator()(const PtrStepSz<float> dmap, PtrStepSz<uchar3> cmap) const
           {
       			const int x = blockIdx.x * blockDim.x + threadIdx.x;
       			const int y = blockIdx.y * blockDim.y + threadIdx.y;
                
       			if (x >= vpointer.dims.x || y >= vpointer.dims.y)
       				return;
       
       			float3 vx = make_float3(x, y, 0) * vpointer.voxel_size;
       			float3 vc =pose.R * vx + pose.t;
       			float3 zstep = make_float3(pose.R.data[2].x, pose.R.data[2].y, pose.R.data[2].z)* vpointer.voxel_size.x;
                Volume::elem_type* vptr=vpointer(x,y);
                for (int z = 1; z < vpointer.dims.z; ++z)
       			{
                    vptr = vpointer.zstep(vptr);
                    vc += zstep;
       				if (vc.z <= 0)
       					continue;
       				const int2 uv = intr.proj(vc);
       				if (uv.x < 0 || uv.x >= dmap.cols || uv.y < 0 || uv.y >= dmap.rows)
       					continue;
       				const float depth = dmap(uv.y, uv.x);
       				if (depth <= 0)
       					continue;
       				const float3 xylambda = intr.reproj(uv.x,uv.y, 1.f);
       				// lambda
       				const float lambda = __m_norm(xylambda);
                    const float sdf = (-1.f) * (__fdividef(1.f, lambda) * __m_norm(vc) - depth);
                    if (sdf >= -vpointer.trun_dist) {
       					const float tsdf = fmin(1.f, __fdividef(sdf, vpointer.trun_dist));
       					const float pre_tsdf = get_voxel_tsdf(*vptr);
       					const int pre_weight = get_voxel_weight(*vptr);
       
       					const int add_weight = 1;
       
       					const int new_weight = min(pre_weight + add_weight, MAX_WEIGHT);
       					const float new_tsdf= __fdividef(__fmaf_rn(pre_tsdf, pre_weight, tsdf), pre_weight + add_weight);
                        set_voxel_tsdf(*vptr, new_tsdf);
                        set_voxel_weight(*vptr, new_weight);


                        float thres_color=__fdividef(vpointer.trun_dist, 2);
                        if (sdf <= thres_color && sdf >= -thres_color) 
                        {
                            uchar3 model_color = get_voxel_color(*vptr);
                            const uchar3 pixel_cmap = cmap(uv.y, uv.x);
                            float c = __int2float_rn(new_weight + add_weight);

                            float m = new_weight * model_color.x + pixel_cmap.x;
                            model_color.x=static_cast<uchar>(__fdividef(m,c));
                            m = new_weight * model_color.y + pixel_cmap.y;
                            model_color.y=static_cast<uchar>(__fdividef(m,c));
                            m = new_weight * model_color.z + pixel_cmap.z;
                            model_color.z=static_cast<uchar>(__fdividef(m,c));
                            set_voxel_color(*vptr, model_color);   
                        }
                       }
                   }
           }
       };
       __global__ void kernel_integrate(const tsdfhelper ther, const PtrStepSz<float> dmap, PtrStepSz<uchar3> cmap) 
       { ther(dmap,cmap); };
       void integrate(const Intrs &intr, const PoseT &pose,Volume &vpointer, const GpuMat &dmap,const GpuMat &cmap)
       {
        tsdfhelper ther(intr, pose, vpointer);

        dim3 block(32, 8);
        dim3 grid(DIVUP(vpointer.dims.x, block.x), DIVUP(vpointer.dims.y, block.y));
        kernel_integrate<<<grid, block>>>(ther, dmap,cmap);
        cudaSafeCall ( cudaDeviceSynchronize() );
       }
    };
}

//TODO:raycast
namespace kf
{
namespace device
{
       __device__ __forceinline__ void intersect(const float3 ray_org, const  float3 ray_dir, /*float3 box_min,*/ const  float3 box_max, float &tnear, float &tfar)
	    {
            const float3 box_min = make_float3(0.f, 0.f, 0.f);

            // compute intersection of ray with all six bbox planes
            float3 invR = make_float3(1.f / ray_dir.x, 1.f / ray_dir.y, 1.f / ray_dir.z);
            float3 tbot = invR * (box_min - ray_org);
            float3 ttop = invR * (box_max - ray_org);
    
            // re-order intersections to find smallest and largest on each axis
            float3 tmin = make_float3(fminf(ttop.x, tbot.x), fminf(ttop.y, tbot.y), fminf(ttop.z, tbot.z));
            float3 tmax = make_float3(fmaxf(ttop.x, tbot.x), fmaxf(ttop.y, tbot.y), fmaxf(ttop.z, tbot.z));
    
            // find the largest tmin and the smallest tmax
            tnear = fmaxf(fmaxf(tmin.x, tmin.y), fmaxf(tmin.x, tmin.z));
            tfar = fminf(fminf(tmax.x, tmax.y), fminf(tmax.x, tmax.z));
	    }
       __device__ float interpolate(const Volume& vpointer, const float3& p_voxels)
        {
            float3 cf = p_voxels;

            //rounding to negative infinity
            int3 g = make_int3(__float2int_rd (cf.x), __float2int_rd (cf.y), __float2int_rd (cf.z));

            if (g.x < 0 || g.x >= vpointer.dims.x - 1 || g.y < 0 || g.y >= vpointer.dims.y - 1 || g.z < 0 || g.z >= vpointer.dims.z - 1)
                return __m_nan();

            float a = cf.x - g.x;
            float b = cf.y - g.y;
            float c = cf.z - g.z;

            float tsdf = 0.f;
            tsdf += get_voxel_tsdf(*vpointer(g.x + 0, g.y + 0, g.z + 0)) * (1 - a) * (1 - b) * (1 - c);
            tsdf += get_voxel_tsdf(*vpointer(g.x + 0, g.y + 0, g.z + 1)) * (1 - a) * (1 - b) *      c;
            tsdf += get_voxel_tsdf(*vpointer(g.x + 0, g.y + 1, g.z + 0)) * (1 - a) *      b  * (1 - c);
            tsdf += get_voxel_tsdf(*vpointer(g.x + 0, g.y + 1, g.z + 1)) * (1 - a) *      b  *      c;
            tsdf += get_voxel_tsdf(*vpointer(g.x + 1, g.y + 0, g.z + 0)) *      a  * (1 - b) * (1 - c);
            tsdf += get_voxel_tsdf(*vpointer(g.x + 1, g.y + 0, g.z + 1)) *      a  * (1 - b) *      c;
            tsdf += get_voxel_tsdf(*vpointer(g.x + 1, g.y + 1, g.z + 0)) *      a  *      b  * (1 - c);
            tsdf += get_voxel_tsdf(*vpointer(g.x + 1, g.y + 1, g.z + 1)) *      a  *      b  *      c;
            return tsdf;
        }
    struct raycasthelper
    {
        const Volume vpointer;
        const Intrs intr;
        const PoseT pose;
        const PoseR Rinv;
        float step_len;
        float3 voxel_size_inv;
        float3 gradient_delta;
        
        raycasthelper(const Intrs& reproj_,const Volume& vpointer_,const PoseT& pose_,const PoseR &Rinv_):
        intr(reproj_),vpointer(vpointer_),pose(pose_),Rinv(Rinv_){
            step_len = vpointer_.voxel_size.x;
            gradient_delta = vpointer_.voxel_size*0.5f;
            voxel_size_inv = 1.f / vpointer.voxel_size;
        };
        __device__ float voxel2tsdf(const float3& p) const
        {
            //rounding to nearest even
            int x = __float2int_rn(p.x * voxel_size_inv.x);
            int y = __float2int_rn(p.y * voxel_size_inv.y);
            int z = __float2int_rn(p.z * voxel_size_inv.z);
            if(x>=vpointer.dims.x-1||y>=vpointer.dims.y-1||z>=vpointer.dims.z-1
            ||x<1||y<1||z<1)
            {
                return __m_nan();
            }
            else
                return get_voxel_tsdf(*vpointer(x, y, z));
        };
        __device__ float3 compute_normal(const float3& p) const
        {
            float3 n;
 
            float Fx1 = interpolate(vpointer, make_float3(p.x + gradient_delta.x, p.y, p.z) * voxel_size_inv);
            float Fx2 = interpolate(vpointer, make_float3(p.x - gradient_delta.x, p.y, p.z) * voxel_size_inv);
            n.x = __fdividef(Fx1 - Fx2, gradient_delta.x);
 
            float Fy1 = interpolate(vpointer, make_float3(p.x, p.y + gradient_delta.y, p.z) * voxel_size_inv);
            float Fy2 = interpolate(vpointer, make_float3(p.x, p.y - gradient_delta.y, p.z) * voxel_size_inv);
            n.y = __fdividef(Fy1 - Fy2, gradient_delta.y);
 
            float Fz1 = interpolate(vpointer, make_float3(p.x, p.y, p.z + gradient_delta.z) * voxel_size_inv);
            float Fz2 = interpolate(vpointer, make_float3(p.x, p.y, p.z - gradient_delta.z) * voxel_size_inv);
            n.z = __fdividef(Fz1 - Fz2, gradient_delta.z);
            __m_normalize(n);
            return n;
        };
        __device__ void operator()(PtrStepSz<float3>vmap, PtrStepSz<float3> nmap)const
        {
            {
                const int x = blockIdx.x * blockDim.x + threadIdx.x;
                const int y = blockIdx.y * blockDim.y + threadIdx.y;
                if (x >= vmap.cols || y >= vmap.rows)
                    return;
                const float3 pixel_position =intr.reproj(x, y, 1.f);
                const float3 ray_org = pose.t;
                float3 ray_dir = pose.R * pixel_position;
                __m_normalize(ray_dir);

                float _near, _far;
                intersect(ray_org, ray_dir, vpointer.volume_range, _near, _far);
                float ray_len = fmax(_near, 0.f);
                if (ray_len >= _far)
                    return;

                const float3 vsetp = ray_dir * vpointer.voxel_size;
                ray_len += step_len;
                float3 nextp = ray_org + ray_dir * ray_len;
                float tsdf_next = voxel2tsdf(nextp);
                float3 vertex = make_float3(0, 0, 0);
                float3 normal = make_float3(0, 0, 0);
                for (; ray_len < _far; ray_len += step_len)
                {
                    nextp += vsetp;
                    float tsdf_cur = tsdf_next;
                    
                    tsdf_next = voxel2tsdf(nextp);
                    if (isnan(tsdf_next))
                        continue;
                    if (tsdf_cur < 0.f && tsdf_next > 0.f)
                        break;
                    if (tsdf_cur > 0.f && tsdf_next < 0.f)
                    {
                        float Ts = ray_len - __fdividef(vpointer.voxel_size.x * tsdf_cur,tsdf_cur-tsdf_next);
                        
                        vertex = ray_org + ray_dir * Ts;
                        normal = compute_normal(vertex);
        
                        if (!isnan(normal.x * normal.y * normal.z))
                        {
                             nmap(y,x) = Rinv *normal;
                             vmap(y,x) = Rinv *(vertex- pose.t);
                             break;
                        }
                    }
                }   
            }
        }
    };
    __global__ void kernal_raycast(const raycasthelper rcher, PtrStepSz<float3> vmap,  PtrStepSz<float3> nmap)
    { rcher(vmap, nmap); };
    void raycast(const Intrs&reproj, const PoseT& pose,const PoseR& Rinv, const Volume &vpointer, GpuMat&vmap, GpuMat &nmap)
    {
        dim3 block(32, 8);
        dim3 grid(DIVUP(vmap.cols, block.x),DIVUP(vmap.rows, block.y));

        raycasthelper rcher(reproj, vpointer, pose, Rinv);
        
        kernal_raycast << <grid, block >> > (rcher, vmap, nmap);
        cudaSafeCall (cudaGetLastError());      
    }
};
}
//TODO: extrace point cloud
namespace kf
{
    namespace device
    {

        enum ScanKind { exclusive, inclusive };

        template<ScanKind Kind, class T>
        __device__ T scan_warp ( volatile T *ptr, const unsigned int idx = threadIdx.x )
        {
            const unsigned int lane = idx & 31;       // index of thread in warp (0..31)

            if (lane >=  1) ptr[idx] = ptr[idx -  1] + ptr[idx];
            if (lane >=  2) ptr[idx] = ptr[idx -  2] + ptr[idx];
            if (lane >=  4) ptr[idx] = ptr[idx -  4] + ptr[idx];
            if (lane >=  8) ptr[idx] = ptr[idx -  8] + ptr[idx];
            if (lane >= 16) ptr[idx] = ptr[idx - 16] + ptr[idx];

            if (Kind == inclusive)
                return ptr[idx];
            else
                return (lane > 0) ? ptr[idx - 1] : 0;
        }


        __device__ int global_count = 0;
        __device__ int output_count;
        __device__ unsigned int blocks_done = 0;


        struct FullScan6
        {
            enum
            {
                CTA_SIZE_X = 32,
                CTA_SIZE_Y = 6,
                CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y,

                MAX_LOCAL_POINTS = 3
            };

            Volume vpointer;
            PoseT aff;

            FullScan6(const Volume& vol) : vpointer(vol) {}

            // __device__ float fetch(int x, int y, int z, int& weight) const
            // {
            //     return unpack_tsdf(*volume(x, y, z), weight);
            // }

            __device__ void operator () (PtrSz<Point3> output) const
            {
                int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
                int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;
                if (__all_sync (__activemask(),x >= vpointer.dims.x) || __all_sync (__activemask(),y >= vpointer.dims.y))
                    return;
                float3 V;
                V.x = (x + 0.5f) * vpointer.voxel_size.x;
                V.y = (y + 0.5f) * vpointer.voxel_size.y;

                int ftid = threadIdx.z * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;

                for (int z = 0; z < vpointer.dims.z - 1; ++z)
                {
                    float3 points[MAX_LOCAL_POINTS];
                    int local_count = 0;

                    if (x < vpointer.dims.x && y < vpointer.dims.y)
                    {
                        int W = get_voxel_weight(*vpointer(x, y, z));
                        float F = get_voxel_tsdf(*vpointer(x, y, z));
                        if (W != 0 && F != 1.f)
                        {
                            V.z = (z + 0.5f) * vpointer.voxel_size.z;

                            //process dx
                            if (x + 1 < vpointer.dims.x)
                            {
                                int Wn = get_voxel_weight(*vpointer(x+1, y, z));
                                float Fn = get_voxel_tsdf(*vpointer(x+1, y, z));

                                if (Wn != 0 && Fn != 1.f)
                                    if ((F > 0 && Fn < 0) || (F < 0 && Fn > 0))
                                    {
                                        float3 p;
                                        p.y = V.y;
                                        p.z = V.z;

                                        float Vnx = V.x + vpointer.voxel_size.x;

                                        float d_inv = 1.f / (fabs (F) + fabs (Fn));
                                        p.x = (V.x * fabs (Fn) + Vnx * fabs (F)) * d_inv;

                                        points[local_count++] = aff.R * p + aff.t;
                                    }
                            }  /* if (x + 1 < volume.dims.x) */

                            //process dy
                            if (y + 1 < vpointer.dims.y)
                            {
                                int Wn = get_voxel_weight(*vpointer(x, y+1, z));
                                float Fn = get_voxel_tsdf(*vpointer(x, y+1, z));

                                if (Wn != 0 && Fn != 1.f)
                                    if ((F > 0 && Fn < 0) || (F < 0 && Fn > 0))
                                    {
                                        float3 p;
                                        p.x = V.x;
                                        p.z = V.z;

                                        float Vny = V.y + vpointer.voxel_size.y;

                                        float d_inv = 1.f / (fabs (F) + fabs (Fn));
                                        p.y = (V.y * fabs (Fn) + Vny * fabs (F)) * d_inv;

                                        points[local_count++] = aff.R * p + aff.t;
                                    }
                            } /*  if (y + 1 < volume.dims.y) */

                            //process dz
                            //if (z + 1 < volume.dims.z) // guaranteed by loop
                            {
                                int Wn = get_voxel_weight(*vpointer(x, y, z+1));
                                float Fn = get_voxel_tsdf(*vpointer(x, y, z+1));

                                if (Wn != 0 && Fn != 1.f)
                                    if ((F > 0 && Fn < 0) || (F < 0 && Fn > 0))
                                    {
                                        float3 p;
                                        p.x = V.x;
                                        p.y = V.y;

                                        float Vnz = V.z + vpointer.voxel_size.z;

                                        float d_inv = 1.f / (fabs (F) + fabs (Fn));
                                        p.z = (V.z * fabs (Fn) + Vnz * fabs (F)) * d_inv;

                                        points[local_count++] = aff.R * p + aff.t;
                                    }
                            } /* if (z + 1 < volume.dims.z) */
                        } /* if (W != 0 && F != 1.f) */
                    } /* if (x < volume.dims.x && y < volume.dims.y) */

                    ///not we fulfilled points array at current iteration
                    int total_warp = __popc (__ballot_sync(__activemask(), local_count > 0)) + __popc (__ballot_sync(__activemask(), local_count > 1)) + __popc (__ballot_sync(__activemask(), local_count > 2));
                    __shared__ float storage_X[CTA_SIZE * MAX_LOCAL_POINTS];
                    __shared__ float storage_Y[CTA_SIZE * MAX_LOCAL_POINTS];
                    __shared__ float storage_Z[CTA_SIZE * MAX_LOCAL_POINTS];

                    if (total_warp > 0)
                    {
                        int lane = Warp::laneId ();
                        int storage_index = (ftid >> Warp::LOG_WARP_SIZE) * Warp::WARP_SIZE * MAX_LOCAL_POINTS;

                        volatile int* cta_buffer = (int*)(storage_X + storage_index);

                        cta_buffer[lane] = local_count;
                        int offset = scan_warp<exclusive>(cta_buffer, lane);

                        if (lane == 0)
                        {
                            int old_global_count = atomicAdd (&global_count, total_warp);
                            cta_buffer[0] = old_global_count;
                        }
                        int old_global_count = cta_buffer[0];

                        for (int l = 0; l < local_count; ++l)
                        {
                            storage_X[storage_index + offset + l] = points[l].x;
                            storage_Y[storage_index + offset + l] = points[l].y;
                            storage_Z[storage_index + offset + l] = points[l].z;
                        }

                        Point3 *pos = output.data + old_global_count + lane;
                        for (int idx = lane; idx < total_warp; idx += Warp::STRIDE, pos += Warp::STRIDE)
                        {
                            float x = storage_X[storage_index + idx];
                            float y = storage_Y[storage_index + idx];
                            float z = storage_Z[storage_index + idx];
                            set_point_pos(*pos,make_float3(x, y, z));
                        }

                        bool full = (old_global_count + total_warp) >= output.size;

                        if (full)
                            break;
                    }
                }
                // prepare for future scans
                if (ftid == 0)
                {
                    unsigned int total_blocks = gridDim.x * gridDim.y * gridDim.z;
                    unsigned int value = atomicInc (&blocks_done, total_blocks);

                    //last block
                    if (value == total_blocks - 1)
                    {
                        output_count = min ((int)output.size, global_count);
                        blocks_done = 0;
                        global_count = 0;
                    }
                }
            }
        };
        __global__ void kernel_extract_points(const FullScan6 fs, PtrSz<Point3> parray) { fs(parray); }
        size_t extract_points(const Volume& vpointer, PtrSz<Point3> parray,const PoseT& pose)
        {
            typedef FullScan6 FS;
            FS fs(vpointer);
            fs.aff = pose;
        
            dim3 block (FS::CTA_SIZE_X, FS::CTA_SIZE_Y);
            dim3 grid (DIVUP (vpointer.dims.x, block.x), DIVUP(vpointer.dims.y, block.y));
        
            kernel_extract_points<<<grid, block>>>(fs, parray);
            cudaSafeCall ( cudaGetLastError () );
            cudaSafeCall (cudaDeviceSynchronize ());
        
            int size;
            cudaSafeCall ( cudaMemcpyFromSymbol (&size, output_count, sizeof(size)) );
            return (size_t)size;
        }
    }
}