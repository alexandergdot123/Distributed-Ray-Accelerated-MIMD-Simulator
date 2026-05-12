#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cfloat>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <string>

#define CUDA_CHECK(call)                                                      \
    do {                                                                      \
        cudaError_t _e = (call);                                              \
        if (_e != cudaSuccess) {                                              \
            fprintf(stderr, "CUDA error %s:%d: %s\n",                        \
                    __FILE__, __LINE__, cudaGetErrorString(_e));              \
            std::exit(1);                                                     \
        }                                                                     \
    } while (0)

#define BVH4_STACK_SIZE 32
#define MAX_LIGHTS      3
#define MAX_BOUNCES     4
#define DEFAULT_SPP     1
#define MAX_SPP         1024
#define SHADOW_EPS      1e-1f

#define SHADOW_PER_PIXEL (MAX_BOUNCES * MAX_LIGHTS)

struct Vec3 { float x, y, z; };

__host__ __device__ inline Vec3 operator+(Vec3 a, Vec3 b){ return {a.x+b.x,a.y+b.y,a.z+b.z}; }
__host__ __device__ inline Vec3 operator-(Vec3 a, Vec3 b){ return {a.x-b.x,a.y-b.y,a.z-b.z}; }
__host__ __device__ inline Vec3 operator*(Vec3 a, float s){ return {a.x*s,a.y*s,a.z*s}; }
__host__ __device__ inline Vec3 operator-(Vec3 a)         { return {-a.x,-a.y,-a.z}; }
__host__ __device__ inline float dot(Vec3 a, Vec3 b)      { return a.x*b.x+a.y*b.y+a.z*b.z; }
__host__ __device__ inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
__host__ __device__ inline Vec3 normalize(Vec3 a) {
    float n = sqrtf(dot(a,a));
    return (n > 0.f) ? a*(1.f/n) : a;
}

__device__ inline uint32_t hash_u32(uint32_t a, uint32_t b, uint32_t c, uint32_t d)
{
    uint32_t h = a * 0x9E3779B1u;
    h ^= (b + 0x9E3779B9u + (h<<6) + (h>>2));
    h ^= (c + 0x9E3779B9u + (h<<6) + (h>>2));
    h ^= (d + 0x9E3779B9u + (h<<6) + (h>>2));
    h ^= h>>16; h *= 0x85EBCA6Bu;
    h ^= h>>13; h *= 0xC2B2AE35u;
    h ^= h>>16;
    return h;
}
__device__ inline float u32_to_float(uint32_t h){
    return (float)((h>>8)&0xFFFFFFu)*(1.f/16777216.f);
}

__device__ inline Vec3 cosine_sample_hemisphere(Vec3 N, float u1, float u2)
{
    float r     = sqrtf(u1);
    float theta = 2.f*3.14159265358979323846f*u2;
    float lx    = r*cosf(theta), ly = r*sinf(theta);
    float lz    = sqrtf(fmaxf(0.f, 1.f-lx*lx-ly*ly));
    Vec3 T;
    if (fabsf(N.z) < 0.999f){
        float inv = 1.f/sqrtf(N.x*N.x+N.y*N.y);
        T = {N.y*inv, -N.x*inv, 0.f};
    } else {
        T = {1.f, 0.f, 0.f};
    }
    Vec3 B = cross(N,T);
    return {T.x*lx+B.x*ly+N.x*lz,
            T.y*lx+B.y*ly+N.y*lz,
            T.z*lx+B.z*ly+N.z*lz};
}

__device__ inline float mtTri(Vec3 ro, Vec3 rd, Vec3 v0, Vec3 v1, Vec3 v2)
{
    Vec3  e1 = v1-v0, e2 = v2-v0;
    Vec3  h  = cross(rd,e2);
    float a  = dot(e1,h);
    if (fabsf(a) < 1e-8f) return -1.f;
    float f  = 1.f/a;
    Vec3  s  = ro-v0;
    float u  = f*dot(s,h);
    if (u<0.f||u>1.f) return -1.f;
    Vec3  q  = cross(s,e1);
    float v  = f*dot(rd,q);
    if (v<0.f||u+v>1.f) return -1.f;
    return f*dot(e2,q);
}

__device__ inline bool slabHit(Vec3 ro, Vec3 inv,
                               float bminx, float bminy, float bminz,
                               float bmaxx, float bmaxy, float bmaxz,
                               float tMaxCap)
{
    float tx0=(bminx-ro.x)*inv.x, tx1=(bmaxx-ro.x)*inv.x;
    float tmin=fminf(tx0,tx1), tmax=fmaxf(tx0,tx1);
    float ty0=(bminy-ro.y)*inv.y, ty1=(bmaxy-ro.y)*inv.y;
    tmin=fmaxf(tmin,fminf(ty0,ty1)); tmax=fminf(tmax,fmaxf(ty0,ty1));
    float tz0=(bminz-ro.z)*inv.z, tz1=(bmaxz-ro.z)*inv.z;
    tmin=fmaxf(tmin,fminf(tz0,tz1)); tmax=fminf(tmax,fmaxf(tz0,tz1));
    return tmax >= fmaxf(tmin,0.f) && tmin < tMaxCap;
}

__device__ int closestHit4(
        Vec3 ro, Vec3 rd, Vec3 inv,
        const float* __restrict__ tris,
        const float* __restrict__ bvh4Bounds,
        const int*   __restrict__ bvh4Meta,
        float& tOut)
{
    tOut = FLT_MAX;
    int bestTri = -1;
    int stack[BVH4_STACK_SIZE];
    int top = 0;
    stack[top++] = 0;

    while (top > 0) {
        int nidx = stack[--top];
        const int* meta = bvh4Meta + nidx * 13;
        int nc = __ldg(meta);

        for (int c = 0; c < nc; ++c) {
            const float* cb = bvh4Bounds + nidx * 24 + c * 6;
            float cminx = __ldg(cb+0), cminy = __ldg(cb+1), cminz = __ldg(cb+2);
            float cmaxx = __ldg(cb+3), cmaxy = __ldg(cb+4), cmaxz = __ldg(cb+5);

            if (!slabHit(ro, inv, cminx, cminy, cminz,
                         cmaxx, cmaxy, cmaxz, tOut))
                continue;

            int cidx    = __ldg(meta + 1 + c*3 + 0);
            int ccount  = __ldg(meta + 1 + c*3 + 1);
            int is_leaf = __ldg(meta + 1 + c*3 + 2);

            if (is_leaf) {
                for (int i = cidx; i < cidx + ccount; ++i) {
                    const float* t = tris + i * 14;
                    Vec3 v0={__ldg(t+0),__ldg(t+1),__ldg(t+2)};
                    Vec3 v1={__ldg(t+3),__ldg(t+4),__ldg(t+5)};
                    Vec3 v2={__ldg(t+6),__ldg(t+7),__ldg(t+8)};
                    float th = mtTri(ro, rd, v0, v1, v2);
                    if (th > 1e-4f && th < tOut) { tOut = th; bestTri = i; }
                }
            } else {
                if (top < BVH4_STACK_SIZE)
                    stack[top++] = cidx;
            }
        }
    }
    return bestTri;
}
__device__ bool anyHit4(
        Vec3 ro, Vec3 rd, Vec3 inv, float tMax,
        const float* __restrict__ tris,
        const float* __restrict__ bvh4Bounds,
        const int*   __restrict__ bvh4Meta)
{
    int stack[BVH4_STACK_SIZE];
    int top = 0;
    stack[top++] = 0;

    while (top > 0) {
        int nidx = stack[--top];
        const int* meta = bvh4Meta + nidx * 13;
        int nc = __ldg(meta);

        for (int c = 0; c < nc; ++c) {
            const float* cb = bvh4Bounds + nidx * 24 + c * 6;
            float cminx = __ldg(cb+0), cminy = __ldg(cb+1), cminz = __ldg(cb+2);
            float cmaxx = __ldg(cb+3), cmaxy = __ldg(cb+4), cmaxz = __ldg(cb+5);

            if (!slabHit(ro, inv, cminx, cminy, cminz,
                         cmaxx, cmaxy, cmaxz, tMax))
                continue;

            int cidx    = __ldg(meta + 1 + c*3 + 0);
            int ccount  = __ldg(meta + 1 + c*3 + 1);
            int is_leaf = __ldg(meta + 1 + c*3 + 2);

            if (is_leaf) {
                for (int i = cidx; i < cidx + ccount; ++i) {
                    const float* t = tris + i * 14;
                    Vec3 v0={__ldg(t+0),__ldg(t+1),__ldg(t+2)};
                    Vec3 v1={__ldg(t+3),__ldg(t+4),__ldg(t+5)};
                    Vec3 v2={__ldg(t+6),__ldg(t+7),__ldg(t+8)};
                    float th = mtTri(ro, rd, v0, v1, v2);
                    if (th > 1e-4f && th < tMax) return true;
                }
            } else {
                if (top < BVH4_STACK_SIZE)
                    stack[top++] = cidx;
            }
        }
    }
    return false;
}

struct ShadowQ {
    float ox, oy, oz;
    float dx, dy, dz;
    float tmax;
    float ndotL;
    float intensity;
    float wtx, wty, wtz;
    int   pixel;
    int   alive;
    int   pad;
};

__constant__ float cLightData[MAX_LIGHTS * 7];
__constant__ int   cNumLights;

__global__ void kTrace(
        const float* __restrict__ tris,
        const float* __restrict__ bvh4Bounds,
        const int*   __restrict__ bvh4Meta,
        ShadowQ*     __restrict__ shadowBuf,
        Vec3   camPos, Vec3 camF, Vec3 camR, Vec3 camU,
        float  tanHalfFov, float aspect,
        int    width, int height, int sample)
{
    const int px = blockIdx.x * blockDim.x + threadIdx.x;
    const int py = blockIdx.y * blockDim.y + threadIdx.y;
    if (px >= width || py >= height) return;

    const int pixel = py * width + px;

    const float u = (2.0f * (px + 0.5f) / (float)width  - 1.0f) * aspect * tanHalfFov;
    const float v = (1.0f - 2.0f * (py + 0.5f) / (float)height) * tanHalfFov;
    Vec3 rd = normalize(camF + camR * u + camU * v);
    Vec3 ro = camPos;
    Vec3 throughput = {1.f, 1.f, 1.f};

    for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
        // Mark shadow slots dead by default
        for (int l = 0; l < MAX_LIGHTS; ++l) {
            int slot = (pixel * MAX_BOUNCES + bounce) * MAX_LIGHTS + l;
            shadowBuf[slot].alive = 0;
        }

        Vec3 invRd = {1.f/rd.x, 1.f/rd.y, 1.f/rd.z};
        float bestT;
        int bestTri = closestHit4(ro, rd, invRd, tris, bvh4Bounds, bvh4Meta, bestT);
        if (bestTri < 0) break;

        const float* t = tris + bestTri * 14;
        Vec3 v0 = {__ldg(t+0),__ldg(t+1),__ldg(t+2)};
        Vec3 v1 = {__ldg(t+3),__ldg(t+4),__ldg(t+5)};
        Vec3 v2 = {__ldg(t+6),__ldg(t+7),__ldg(t+8)};
        Vec3 M  = {__ldg(t+9),__ldg(t+10),__ldg(t+11)};
        float metallic  = __ldg(t+12);
        float roughness = __ldg(t+13);

        Vec3 P = ro + rd * bestT;
        Vec3 N = normalize(cross(v1 - v0, v2 - v0));
        if (dot(N, rd) > 0.0f) N = -N;
        Vec3 Poff = {P.x + N.x * SHADOW_EPS,
                     P.y + N.y * SHADOW_EPS,
                     P.z + N.z * SHADOW_EPS};

        // Shadow contribution is gated by (1 - metallic).
        // metallic=0 -> full direct lighting (current behavior)
        // metallic=1 -> direct lighting suppressed; only bounce contributes
        float diffuseWeight = 1.0f - metallic;

        // Emit shadow queries
        int numL = cNumLights;
        for (int l = 0; l < numL; ++l) {
            const float* L = cLightData + l * 7;
            Vec3  Lpos  = {L[0], L[1], L[2]};
            Vec3  Lcol  = {L[3], L[4], L[5]};
            float Lint  = L[6];
            Vec3  toL   = Lpos - P;
            float distL = sqrtf(dot(toL, toL));
            if (distL < 1e-6f) continue;
            Vec3  Ldir  = toL * (1.0f / distL);
            float ndotL = dot(N, Ldir);
            if (ndotL <= 0.0f) continue;

            int slot = (pixel * MAX_BOUNCES + bounce) * MAX_LIGHTS + l;
            ShadowQ& sq  = shadowBuf[slot];
            sq.ox = Poff.x; sq.oy = Poff.y; sq.oz = Poff.z;
            sq.dx = Ldir.x; sq.dy = Ldir.y; sq.dz = Ldir.z;
            sq.tmax      = distL - SHADOW_EPS;
            sq.ndotL     = ndotL;
            sq.intensity = Lint;
            // Pre-multiply throughput by (1 - metallic) so kShadow's atomicAdd
            // adds 0 contribution for fully metallic surfaces.
            sq.wtx = throughput.x * M.x * Lcol.x * diffuseWeight;
            sq.wty = throughput.y * M.y * Lcol.y * diffuseWeight;
            sq.wtz = throughput.z * M.z * Lcol.z * diffuseWeight;
            sq.pixel = pixel;
            sq.alive = 1;
            sq.pad   = 0;
        }

        if (bounce == MAX_BOUNCES - 1) break;

        // Sample bounce direction by lerping between mirror reflection
        // and cosine-weighted random.
        //   roughness=0 -> pure mirror (rd reflected about N)
        //   roughness=1 -> fully random cosine sample (current behavior)
        uint32_t seed_b = (uint32_t)bounce * 65536u + (uint32_t)sample;
        uint32_t h1 = hash_u32((uint32_t)px, (uint32_t)py, seed_b, 0u);
        uint32_t h2 = hash_u32((uint32_t)px, (uint32_t)py, seed_b, 1u);
        Vec3 randomDir = cosine_sample_hemisphere(N, u32_to_float(h1), u32_to_float(h2));

        // Mirror reflection: rd' = rd - 2*(rd.N)*N
        float rdN = dot(rd, N);
        Vec3 mirrorDir = {rd.x - 2.0f*rdN*N.x,
                          rd.y - 2.0f*rdN*N.y,
                          rd.z - 2.0f*rdN*N.z};

        // Lerp between mirror and random by roughness, then renormalize.
        Vec3 nextDir = {
            mirrorDir.x + (randomDir.x - mirrorDir.x) * roughness,
            mirrorDir.y + (randomDir.y - mirrorDir.y) * roughness,
            mirrorDir.z + (randomDir.z - mirrorDir.z) * roughness
        };
        nextDir = normalize(nextDir);

        throughput.x *= M.x;
        throughput.y *= M.y;
        throughput.z *= M.z;

        ro = Poff;
        rd = nextDir;
    }
}

__global__ void kShadow(
        const ShadowQ* __restrict__ shadowBuf,
        const float*   __restrict__ tris,
        const float*   __restrict__ bvh4Bounds,
        const int*     __restrict__ bvh4Meta,
        float*         __restrict__ accumR,
        float*         __restrict__ accumG,
        float*         __restrict__ accumB,
        int numShadow)
{
    for (int si = blockIdx.x*blockDim.x + threadIdx.x;
             si < numShadow;
             si += gridDim.x*blockDim.x)
    {
        const ShadowQ& sq = shadowBuf[si];
        if (!sq.alive) continue;

        Vec3 ro  = {sq.ox, sq.oy, sq.oz};
        Vec3 rd  = {sq.dx, sq.dy, sq.dz};
        Vec3 inv = {1.f/rd.x, 1.f/rd.y, 1.f/rd.z};

        if (anyHit4(ro, rd, inv, sq.tmax, tris, bvh4Bounds, bvh4Meta))
            continue;

        float k = sq.intensity * sq.ndotL;
        int   p = sq.pixel;
        atomicAdd(&accumR[p], sq.wtx * k);
        atomicAdd(&accumG[p], sq.wty * k);
        atomicAdd(&accumB[p], sq.wtz * k);
    }
}

__global__ void kFinalize(
        const float* __restrict__ accumR,
        const float* __restrict__ accumG,
        const float* __restrict__ accumB,
        uchar3* __restrict__ img,
        int numPixels, float invSpp)
{
    int p = blockIdx.x*blockDim.x + threadIdx.x;
    if (p >= numPixels) return;
    auto clamp01 = [](float x){ return fminf(fmaxf(x,0.f),1.f); };
    img[p] = {
        (unsigned char)(clamp01(accumR[p]*invSpp)*255.f+0.5f),
        (unsigned char)(clamp01(accumG[p]*invSpp)*255.f+0.5f),
        (unsigned char)(clamp01(accumB[p]*invSpp)*255.f+0.5f)
    };
}

static inline uint32_t expandBitsHost(uint32_t v)
{
    v = (v * 0x00010001u) & 0xFF0000FFu;
    v = (v * 0x00000101u) & 0x0F00F00Fu;
    v = (v * 0x00000011u) & 0xC30C30C3u;
    v = (v * 0x00000005u) & 0x49249249u;
    return v;
}

static uint32_t mortonCode(float ox, float oy, float oz,
                           float3 sceneMin, float3 sceneExtentInv)
{
    float nx = (ox - sceneMin.x) * sceneExtentInv.x;
    float ny = (oy - sceneMin.y) * sceneExtentInv.y;
    float nz = (oz - sceneMin.z) * sceneExtentInv.z;
    nx = std::min(std::max(nx, 0.f), 1.f);
    ny = std::min(std::max(ny, 0.f), 1.f);
    nz = std::min(std::max(nz, 0.f), 1.f);
    uint32_t ix = (uint32_t)(nx * 1023.f);
    uint32_t iy = (uint32_t)(ny * 1023.f);
    uint32_t iz = (uint32_t)(nz * 1023.f);
    return (expandBitsHost(ix) << 2) | (expandBitsHost(iy) << 1) | expandBitsHost(iz);
}

static void hostMortonSort(std::vector<ShadowQ>& buf,
                           float3 sceneMin, float3 sceneExtentInv)
{
    int n = (int)buf.size();

    // Build (key, index) pairs
    std::vector<std::pair<uint32_t, int>> kv(n);
    for (int i = 0; i < n; ++i) {
        if (buf[i].alive)
            kv[i] = {mortonCode(buf[i].ox, buf[i].oy, buf[i].oz,
                                sceneMin, sceneExtentInv), i};
        else
            kv[i] = {0xFFFFFFFFu, i};  // dead queries sort to end
    }

    // Sort by Morton code
    std::sort(kv.begin(), kv.end(),
              [](const std::pair<uint32_t,int>& a,
                 const std::pair<uint32_t,int>& b){ return a.first < b.first; });

    // Gather into sorted order
    std::vector<ShadowQ> sorted(n);
    for (int i = 0; i < n; ++i)
        sorted[i] = buf[kv[i].second];
    buf.swap(sorted);
}

static bool loadScene(const std::string& path, std::vector<float>& out, int& n)
{
    FILE* fp = std::fopen(path.c_str(),"r");
    if (!fp){ std::perror(path.c_str()); return false; }
    if (std::fscanf(fp,"%d",&n)!=1){ std::fclose(fp); return false; }
    out.resize((size_t)n*14);

    // Use line-based parsing so we can robustly detect whether a triangle
    // has 12 floats (legacy) or 14 floats (with metallic/roughness).
    // Skip the rest of the count line first.
    int ch;
    while ((ch = std::fgetc(fp)) != EOF && ch != '\n') {}

    char line[1024];
    for (int i = 0; i < n; ++i) {
        if (!std::fgets(line, sizeof line, fp)) {
            std::fclose(fp);
            return false;
        }
        float* t = out.data() + i*14;
        float metal = 0.0f, rough = 1.0f;
        int got = std::sscanf(line, "%f %f %f %f %f %f %f %f %f %f %f %f %f %f",
                              t+0,t+1,t+2,t+3,t+4,t+5,t+6,t+7,t+8,t+9,t+10,t+11,
                              &metal, &rough);
        if (got < 12) {
            std::fprintf(stderr, "[host] scene.txt: triangle %d has only %d floats (need 12+)\n",
                         i, got);
            std::fclose(fp);
            return false;
        }
        // got == 12: legacy file, defaults apply
        // got == 14: new file with metallic/roughness
        t[12] = metal;
        t[13] = rough;
    }
    std::fclose(fp);
    std::printf("[host] loaded %d triangles (14 floats each: pos9 + col3 + metallic + roughness)\n",n);
    return true;
}

static bool loadBVH4(const std::string& path,
                     std::vector<float>& bounds, std::vector<int>& meta, int& numNodes)
{
    FILE* fp = std::fopen(path.c_str(),"r");
    if (!fp){ std::perror(path.c_str()); return false; }
    if (std::fscanf(fp,"%d",&numNodes)!=1){ std::fclose(fp); return false; }
    bounds.resize((size_t)numNodes*24);
    meta.resize((size_t)numNodes*13);
    for (int i=0;i<numNodes;++i){
        int nc;
        if (std::fscanf(fp,"%d",&nc)!=1){ std::fclose(fp); return false; }
        meta[i*13] = nc;
        for (int c=0;c<4;++c){
            float* b = bounds.data()+i*24+c*6;
            int*   m = meta.data()+i*13+1+c*3;
            if (std::fscanf(fp,"%f%f%f%f%f%f%d%d%d",
                            b+0,b+1,b+2,b+3,b+4,b+5,m+0,m+1,m+2)!=9)
            { std::fclose(fp); return false; }
        }
    }
    std::fclose(fp);
    std::printf("[host] loaded %d BVH4 nodes\n",numNodes);
    return true;
}

struct Camera { Vec3 pos,dir,up; float fov; int W,H; };

static bool loadCamera(const std::string& path, Camera& c)
{
    FILE* fp = std::fopen(path.c_str(),"r");
    if (!fp){ std::perror(path.c_str()); return false; }
    int ok=0;
    ok+=std::fscanf(fp,"%f%f%f",&c.pos.x,&c.pos.y,&c.pos.z);
    ok+=std::fscanf(fp,"%f%f%f",&c.dir.x,&c.dir.y,&c.dir.z);
    ok+=std::fscanf(fp,"%f%f%f",&c.up.x, &c.up.y, &c.up.z);
    ok+=std::fscanf(fp,"%f%d%d",&c.fov,  &c.W,    &c.H);
    std::fclose(fp);
    if (ok!=12) return false;
    std::printf("[host] camera: pos(%.1f %.1f %.1f) dir(%.3f %.3f %.3f) fov=%.1f %dx%d\n",
                c.pos.x,c.pos.y,c.pos.z,c.dir.x,c.dir.y,c.dir.z,c.fov,c.W,c.H);
    return true;
}

static bool loadLights(const std::string& path, std::vector<float>& flat, int& numLights)
{
    FILE* fp = std::fopen(path.c_str(),"r");
    if (!fp){ std::perror(path.c_str()); return false; }
    numLights=0; flat.clear();
    char line[512];
    while (std::fgets(line,sizeof line,fp)){
        char* p=line; while(*p==' '||*p=='\t')++p;
        if(*p=='\n'||*p=='\r'||*p=='\0'||*p=='#') continue;
        float f[7];
        if(std::sscanf(p,"%f%f%f%f%f%f%f",f+0,f+1,f+2,f+3,f+4,f+5,f+6)!=7) continue;
        if(numLights>=MAX_LIGHTS) break;
        for(int i=0;i<7;++i) flat.push_back(f[i]);
        ++numLights;
    }
    std::fclose(fp);
    std::printf("[host] loaded %d light(s)\n",numLights);
    return numLights > 0;
}

static bool writePPM(const std::string& path, const std::vector<uchar3>& img, int W, int H)
{
    FILE* fp = std::fopen(path.c_str(),"wb");
    if (!fp){ std::perror(path.c_str()); return false; }
    std::fprintf(fp,"P6\n%d %d\n255\n",W,H);
    std::fwrite(img.data(),3,(size_t)W*H,fp);
    std::fclose(fp);
    std::printf("[host] wrote %s (%dx%d)\n",path.c_str(),W,H);
    return true;
}

int main(int argc, char** argv)
{
    int spp = DEFAULT_SPP;
    std::vector<std::string> positional;
    for (int i=1;i<argc;++i){
        std::string a=argv[i];
        if (a=="--spp"&&i+1<argc){
            spp=std::atoi(argv[++i]);
            if(spp<1) spp=1;
            if(spp>MAX_SPP) spp=MAX_SPP;
        } else positional.push_back(a);
    }
    auto pos_or=[&](size_t i,const char* d){
        return i<positional.size()?positional[i]:std::string(d);
    };
    std::string scenePath  = pos_or(0,"scene.txt");
    std::string cameraPath = pos_or(1,"camera.txt");
    std::string bvhPath    = pos_or(2,"bvh4.txt");
    std::string lightsPath = pos_or(3,"lights.txt");
    std::string outPath    = pos_or(4,"output.ppm");

    std::printf("[host] spp = %d\n",spp);

    std::vector<float> tris;       int numTris  = 0;
    std::vector<float> bvh4Bounds; int numNodes = 0;
    std::vector<int>   bvh4Meta;
    Camera cam;
    std::vector<float> lightFlat;  int numLights = 0;

    if (!loadScene(scenePath,   tris,       numTris))              return 1;
    if (!loadBVH4(bvhPath,      bvh4Bounds, bvh4Meta, numNodes))   return 1;
    if (!loadCamera(cameraPath, cam))                              return 1;
    if (!loadLights(lightsPath, lightFlat,  numLights))            return 1;

    int W=cam.W, H=cam.H, numPixels=W*H;

    Vec3 F = normalize(cam.dir);
    Vec3 R = normalize(cross(F, normalize(cam.up)));
    Vec3 U = cross(R,F);
    float tanHalfFov = std::tan(cam.fov*0.5f*3.14159265358979323846f/180.f);
    float aspect = (float)W/(float)H;

    // Upload geometry + BVH4
    float *dTris=nullptr, *dBounds=nullptr;
    int   *dMeta=nullptr;
    CUDA_CHECK(cudaMalloc(&dTris,   sizeof(float)*tris.size()));
    CUDA_CHECK(cudaMalloc(&dBounds, sizeof(float)*bvh4Bounds.size()));
    CUDA_CHECK(cudaMalloc(&dMeta,   sizeof(int)  *bvh4Meta.size()));
    CUDA_CHECK(cudaMemcpy(dTris,   tris.data(),       sizeof(float)*tris.size(),       cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dBounds, bvh4Bounds.data(), sizeof(float)*bvh4Bounds.size(), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dMeta,   bvh4Meta.data(),   sizeof(int)  *bvh4Meta.size(),   cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpyToSymbol(cLightData,lightFlat.data(),sizeof(float)*lightFlat.size()));
    CUDA_CHECK(cudaMemcpyToSymbol(cNumLights,&numLights,sizeof(int)));

    std::printf("[host] uploaded %.1f MB tris + %.1f MB BVH4\n",
                sizeof(float)*tris.size()/(1024.0*1024.0),
                (sizeof(float)*bvh4Bounds.size()+sizeof(int)*bvh4Meta.size())/(1024.0*1024.0));

    // Per-pixel accumulators
    float *dAccumR=nullptr, *dAccumG=nullptr, *dAccumB=nullptr;
    CUDA_CHECK(cudaMalloc(&dAccumR, sizeof(float)*numPixels));
    CUDA_CHECK(cudaMalloc(&dAccumG, sizeof(float)*numPixels));
    CUDA_CHECK(cudaMalloc(&dAccumB, sizeof(float)*numPixels));
    CUDA_CHECK(cudaMemset(dAccumR, 0, sizeof(float)*numPixels));
    CUDA_CHECK(cudaMemset(dAccumG, 0, sizeof(float)*numPixels));
    CUDA_CHECK(cudaMemset(dAccumB, 0, sizeof(float)*numPixels));

    // Shadow buffer on device
    int shadowSlots = numPixels * SHADOW_PER_PIXEL;
    ShadowQ *dShadow = nullptr;
    CUDA_CHECK(cudaMalloc(&dShadow, sizeof(ShadowQ)*shadowSlots));

    // Host shadow buffer for sorting
    std::vector<ShadowQ> hShadow(shadowSlots);

    uchar3 *dImg = nullptr;
    CUDA_CHECK(cudaMalloc(&dImg, sizeof(uchar3)*numPixels));

    // Grid configs
    dim3 traceBlock(16, 16);
    dim3 traceGrid((W+15)/16, (H+15)/16);
    int shadowBlock = 128;
    int shadowGrid  = (shadowSlots + shadowBlock - 1) / shadowBlock;

    // Scene AABB for Morton normalization
    float3 sceneMin = {FLT_MAX, FLT_MAX, FLT_MAX};
    float3 sceneMax = {-FLT_MAX, -FLT_MAX, -FLT_MAX};
    for (int i = 0; i < numTris; ++i) {
        const float* t = tris.data() + i*12;
        for (int v = 0; v < 3; ++v) {
            sceneMin.x = std::min(sceneMin.x, t[v*3+0]);
            sceneMin.y = std::min(sceneMin.y, t[v*3+1]);
            sceneMin.z = std::min(sceneMin.z, t[v*3+2]);
            sceneMax.x = std::max(sceneMax.x, t[v*3+0]);
            sceneMax.y = std::max(sceneMax.y, t[v*3+1]);
            sceneMax.z = std::max(sceneMax.z, t[v*3+2]);
        }
    }
    float3 sceneExtentInv = {
        1.f / std::max(sceneMax.x - sceneMin.x, 1e-6f),
        1.f / std::max(sceneMax.y - sceneMin.y, 1e-6f),
        1.f / std::max(sceneMax.z - sceneMin.z, 1e-6f)
    };

    cudaEvent_t e0, e1;
    cudaEventCreate(&e0); cudaEventCreate(&e1);
    cudaEventRecord(e0);

    for (int s = 0; s < spp; ++s) {
        // Zero shadow buffer
        CUDA_CHECK(cudaMemset(dShadow, 0, sizeof(ShadowQ)*shadowSlots));

        // A: monolithic trace — all bounces in one kernel
        kTrace<<<traceGrid, traceBlock>>>(
            dTris, dBounds, dMeta, dShadow,
            cam.pos, F, R, U, tanHalfFov, aspect, W, H, s);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        // Host-side Morton sort: download, sort, upload
        CUDA_CHECK(cudaMemcpy(hShadow.data(), dShadow,
                              sizeof(ShadowQ)*shadowSlots, cudaMemcpyDeviceToHost));
        hostMortonSort(hShadow, sceneMin, sceneExtentInv);
        CUDA_CHECK(cudaMemcpy(dShadow, hShadow.data(),
                              sizeof(ShadowQ)*shadowSlots, cudaMemcpyHostToDevice));

        // B: shadow any-hit on sorted queries + accumulate
        kShadow<<<shadowGrid, shadowBlock>>>(
            dShadow, dTris, dBounds, dMeta,
            dAccumR, dAccumG, dAccumB, shadowSlots);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    cudaEventRecord(e1);
    cudaEventSynchronize(e1);
    float ms = 0.f;
    cudaEventElapsedTime(&ms, e0, e1);

    long long rpp = (long long)(MAX_BOUNCES + MAX_BOUNCES * numLights) * spp;
    std::printf("[host] kernel: %.1f ms  (~%.2f Mrays/s  %lld rays/pixel * %d spp)\n",
                ms, (double)numPixels*rpp/(ms*1000.0), rpp/spp, spp);

    // C: finalize
    kFinalize<<<(numPixels+255)/256, 256>>>(
        dAccumR, dAccumG, dAccumB, dImg, numPixels, 1.f/(float)spp);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    std::vector<uchar3> img(numPixels);
    CUDA_CHECK(cudaMemcpy(img.data(), dImg, sizeof(uchar3)*numPixels, cudaMemcpyDeviceToHost));
    writePPM(outPath, img, W, H);

    cudaFree(dTris); cudaFree(dBounds); cudaFree(dMeta);
    cudaFree(dAccumR); cudaFree(dAccumG); cudaFree(dAccumB);
    cudaFree(dShadow); cudaFree(dImg);
    cudaEventDestroy(e0); cudaEventDestroy(e1);
    return 0;
}
