// metal/placeholder.metal — temporary placeholder so the metallib build
// step has at least one kernel. Replaced by metal/types.metal in A6.

#include <metal_stdlib>
using namespace metal;

kernel void grdPlaceholderKernel(
    device uint *out [[buffer(0)]],
    uint gid [[thread_position_in_grid]]) {
  out[gid] = gid;
}