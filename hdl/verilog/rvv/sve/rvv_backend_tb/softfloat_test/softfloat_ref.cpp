// Host-FPU reference for the SystemVerilog soft-float package (rvv_softfloat.svh).
// Compiled by Verilator as a DPI-C source. Rounding mode and flags come from <fenv.h>, so RMM
// (which fenv has no mode for) is not covered here.
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <svdpi.h>

#pragma STDC FENV_ACCESS ON

namespace {
float as_f(uint32_t v) { float f; std::memcpy(&f, &v, 4); return f; }
uint32_t as_u(float f) { uint32_t v; std::memcpy(&v, &f, 4); return v; }

void set_rm(int rm) {
  switch (rm) {
    case 0: std::fesetround(FE_TONEAREST); break;
    case 1: std::fesetround(FE_TOWARDZERO); break;
    case 2: std::fesetround(FE_DOWNWARD); break;
    default: std::fesetround(FE_UPWARD); break;
  }
}

// {NV, DZ, OF, UF, NX}
int get_flags() {
  int f = 0;
  if (std::fetestexcept(FE_INVALID))   f |= 16;
  if (std::fetestexcept(FE_DIVBYZERO)) f |= 8;
  if (std::fetestexcept(FE_OVERFLOW))  f |= 4;
  if (std::fetestexcept(FE_UNDERFLOW)) f |= 2;
  if (std::fetestexcept(FE_INEXACT))   f |= 1;
  return f;
}

uint32_t canon(uint32_t v) { return ((v & 0x7f800000u) == 0x7f800000u && (v & 0x7fffffu)) ? 0x7fc00000u : v; }
}  // namespace

extern "C" {

// op: 0 add, 1 sub, 2 mul, 3 div, 4 fma, 5 sqrt
int ref_op(int op, int a, int b, int c, int rm, int* flags) {
  volatile float fa = as_f(a), fb = as_f(b), fc = as_f(c);
  volatile float r = 0;
  set_rm(rm);
  std::feclearexcept(FE_ALL_EXCEPT);
  switch (op) {
    case 0: r = fa + fb; break;
    case 1: r = fa - fb; break;
    case 2: r = fa * fb; break;
    case 3: r = fa / fb; break;
    case 4: r = fmaf(fa, fb, fc); break;
    default: r = sqrtf(fa); break;
  }
  *flags = get_flags();
  std::fesetround(FE_TONEAREST);
  return (int)canon(as_u(r));
}

// float -> integer of `bits` width. Out of range / NaN: saturate with NV.
int ref_to_int(int a, int rm, int is_signed, int bits, int* flags) {
  volatile float fa = as_f(a);
  set_rm(rm);
  std::feclearexcept(FE_ALL_EXCEPT);
  volatile float r = std::rintf(fa);
  int fl = get_flags();
  std::fesetround(FE_TONEAREST);
  double d = r;
  double maxv = is_signed ? std::ldexp(1.0, bits - 1) - 1 : std::ldexp(1.0, bits) - 1;
  double minv = is_signed ? -std::ldexp(1.0, bits - 1) : 0;
  uint32_t out;
  if (std::isnan(fa)) {
    *flags = 16; out = (uint32_t)(int64_t)maxv; return (int)out;
  }
  if (d > maxv) { *flags = 16; return (int)(uint32_t)(int64_t)maxv; }
  if (d < minv) { *flags = 16; return (int)(uint32_t)(int64_t)minv; }
  *flags = fl & 1;   // only inexact can remain
  return (int)(uint32_t)(int64_t)d;
}

int ref_from_int(int x, int rm, int is_signed, int bits, int* flags) {
  int64_t v;
  if (is_signed) {
    v = (int64_t)(int32_t)((uint32_t)x << (32 - bits)) >> (32 - bits);
  } else {
    v = (uint64_t)(uint32_t)x & ((bits == 32) ? 0xffffffffull : ((1ull << bits) - 1));
  }
  set_rm(rm);
  std::feclearexcept(FE_ALL_EXCEPT);
  volatile float r = (float)v;
  *flags = get_flags();
  std::fesetround(FE_TONEAREST);
  return (int)as_u(r);
}

}  // extern "C"
