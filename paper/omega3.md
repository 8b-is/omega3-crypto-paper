# Ω₃: Balanced-Ternary Encoding, Exact Dyadic Arithmetic, and Capability-Sealed Reconciliation

**Peter Lodri** · 8b-is × Vaked × Aurora · 2026-11

---

## Abstract

We describe Ω₃, a small family of primitives for representing and reconciling
state in a distributed, capability-constrained system without floating-point
drift and without ambient authority. The construction rests on three exact
ideas: (1) **balanced-ternary packing** of `{-1, 0, +1}` weights into
`base-243` bytes at `1.585 bits/trit`; (2) **exact dyadic rationals** `ℤ[1/2]`
for all arithmetic on the hot path, so that reconciliation is bit-identical
across architectures; and (3) a **capability ABI** in which every resource is
addressed by an opaque 64-bit handle gated by a fixed set of checks, with a
root-seal capability that can never be exported. We give the wire formats, the
invariants, and the verified test vectors. This is a construction paper: every
claim is backed by a test in the reference implementation.

---

## 1. Introduction

Distributed state reconciliation usually pays two taxes: **precision** (floating
point is not associative, so replicas drift) and **authority** (a process that
can name a resource can usually touch it). Ω₃ removes both by construction:

- All state deltas are **exact dyadic rationals** `m / 2^k`, closed under
  addition, subtraction, and the semilattice join. No rounding, ever.
- All resource access is **capability-mediated**: a `VirtualCapHandle64` names a
  slice, and a fixed 7-gate check decides whether the access is permitted. There
  are no raw pointers and no syscall numbers in the guest.

The encoding layer — balanced ternary packed at `base-243` — is the compact
carrier for ternary-quantized weights and for the 6-register "signal" records
used elsewhere in the constellation.

---

## 2. Balanced-ternary packing (SPQT `base-243`)

A balanced trit is `t ∈ {-1, 0, +1}`. Map it to an unsigned digit
`u = t + 1 ∈ {0, 1, 2}`. Five trits pack into one byte:

```
B = Σ_{m=0}^{4} u_m · 3^m  ∈ [0, 242]
```

Since `3^5 = 243 ≤ 256`, every 5-trit group fits in a byte with 13 unused codes
(`243..255`) reserved as invalid. The density is `log2(3) ≈ 1.585 bits/trit`,
versus `2 bits/trit` for naive 2-bit storage — a `1.262×` improvement, and
`8×` over FP16 for ternary weights.

The reference packer is a single branchless helper shared by both the arena
packer and the in-register fold:

```rust
#[inline]
const fn pack_trit_chunk(trits: &[i8], start: usize, end: usize) -> u8 {
    let mut byte_val = 0u8;
    let mut pow3 = 1u8;
    let mut k = start;
    while k < end {
        let t = trits[k];
        let digit = ((t > 0) as u8) * 2 + ((t == 0) as u8); // branchless t+1
        byte_val = byte_val.wrapping_add(digit.wrapping_mul(pow3));
        pow3 = pow3.wrapping_mul(3);
        k += 1;
    }
    byte_val
}
```

The digit map `((t>0) as u8)*2 + ((t==0) as u8)` is bit-identical to the
reference `if t<0 {0} else if t==0 {1} else {2}` for **every** `i8`, proven by an
exhaustive test over `i8::MIN..=i8::MAX`. The three canonical 5-trit chunks are
`[+1,+1,+1,+1,+1] → 242`, `[-1,-1,-1,-1,-1] → 0`, and `[0,0,0,0,0] → 121`.

### 2.1 The `LitanyWireFrame`

Integrity is carried by a 64-byte, cache-line-aligned frame:

```rust
#[repr(C, align(64))]
pub struct LitanyWireFrame {
    pub frame32: [u8; 32],   // 32-byte seal (folds + lengths + gate + ABI)
    pub bfp64_pos: u64,      // BFP-64 positive bitplane
    pub bfp64_neg: u64,      // BFP-64 negative bitplane
    pub ratio_p: u32,        // exact p/q compression ratio
    pub ratio_q: u32,
    pub spqt_root: [u8; 3],  // 15-bit SPQT base-243 root
    pub qt_mask: u8,         // quantization bitplane mask (qt:55)
    pub lanes_active: u16,
    pub wire_seal16: u16,    // 16-bit XOR tail over bytes 0..62
}
```

The 64-bit fold is partitioned into disjoint positive/negative bitplanes by the
`qt` mask (`pos & neg == 0`), and the whole frame is sealed by a 16-bit XOR over
its first 62 bytes. The canonical fold at `qt:55`, gate `0x62` is
`0xe1034e575c371ab0`, whose bitplane split is
`pos = 0x4101445554151010`, `neg = 0xa0020a0208220aa0` — pinned by a Go↔Rust
parity test in `spherepop-kernel`.

---

## 3. Exact dyadic arithmetic (`ℤ[1/2]`)

A dyadic rational is `q = m / 2^k` with `m ∈ ℤ`, `k ∈ ℕ`. With a fixed scale
`k = 16`, we represent `q` as a single `i64` mantissa:

```rust
#[repr(transparent)]
pub struct Dyadic64(pub i64); // q = mantissa / 2^16
```

Addition and subtraction are integer add/sub (closed and exact). The semilattice
join is `max`. Because every operation stays inside `ℤ[1/2]` at a common scale,
there is **no rounding and no non-associativity**: two replicas that apply the
same deltas in any order reach the same bits. This is the property that makes
reconciliation deterministic across x86-64, ARM64, and bare-metal targets.

Compression ratios are likewise exact: `RationalPQ { p, q }` with `gcd(p,q)=1`,
so a `3761/3314` ratio is stored as two integers, never a float.

---

## 4. Capability ABI

Every host resource — a shared-memory slice, a `.m8` container, a 3-byte SPQT
signal, a 216-byte radio frame, a DMA ring — is addressed by an opaque
`VirtualCapHandle64`:

```
VirtualCapHandle64 = (epoch_gen, cap_slot_id, futhark_tag_r2, block_offset)
```

A guest invokes resources only through `Op::Cap(handle, op, args)`. The host
resolves the handle through a capability table gated by seven checks:

1. **Alignment** — `byte_align == 0` (64-byte cache line).
2. **Charm XVIII** — `CAP_ROOT_SEAL` (`0x8000_0000`) is never exported.
3. **Ternary polarity** — `{-1: guard, 0: read-only, +1: read-write}`.
4. **Epoch match** — `handle.epoch_gen == pte.expected_epoch` (no use-after-free
   across hot-swap safe points).
5. **Futhark tag** — the `3^3 = 27`-state domain tag matches.
6. **Slice bounds** — `block_offset + xfer_beats ≤ max_blocks` (carry-safe).
7. **Subset authorization** — `(req_caps & allowed_caps) == req_caps`.

Because the same compiled guest runs against a POSIX `mmap` backend, a WASM
linear-memory backend, and a bare-metal DMA backend, the capability boundary is
the *only* thing that differs between targets — the guest logic is identical.

---

## 5. DEC / Cartan-torsion reconciliation

Concurrent branches in an asynchronous system do not commute without
reconciliation. We model the execution history as an oriented cell complex and
the reconciliation defect as a **discrete Cartan torsion** 2-cochain.

- **0-cochains** `C⁰`: replicated state vectors (version clocks + dyadic values).
- **1-cochains** `C¹`: the soldering form `θ([v_i, v_j]) = s(v_j) − s(v_i)`.
- **2-cochains** `C²`: the torsion `T(σ) = ∮_{∂σ} θ`, the translational defect
  between two concurrent branches.

The join operator `⊔` (element-wise `sup`) is the retraction `𝒫_⊔` that absorbs
the torsion defect into a confluent state. After the join, discrete Stokes'
theorem holds exactly: `∮_{∂Σ} θ = 0`. Because the arithmetic is dyadic, this
closure is bit-exact — the reconciliation is a proof, not an approximation.

A 64-byte `WireC1Frame` (`magic 0x8B15`) carries one such delta with **zero
implicit padding** (all fields are primitive integers, `size_of == 64`,
`align_of == 8`), so it can be cast from a network buffer without undefined
behavior. Idempotent ingestion guards on the causal clock
(`incoming == local + 1`) so duplicate or reordered frames are safely ignored.

---

## 6. Verified test vectors

| Property | Vector | Where |
|---|---|---|
| SPQT 5-trit chunks | `242`, `0`, `121` | `wupz-core` `pack_trit_chunk` test |
| Canonical fold @ `qt:55` | `0xe1034e575c371ab0` | `wupz-core` + `spherepop-kernel` |
| BFP-64 split | `pos=0x4101445554151010`, `neg=0xa0020a0208220aa0` | Go↔Rust parity |
| 32-byte seal | `6200…f20c` for `([0x62;3761],[0x33;3314],0x62)` | Go↔Rust parity |
| Ternary quantizer | trits `[1,-1,0,1,-1,0,1,-1]`, scale `15513/16384` | `upz` golden + MLX-QUANT float ref |
| C ABI parity | `fold=0xe7e59050171f1e25`, `popcount=73`, `diff=10` | `abi_smoke` |

All of the above run in CI on both GitHub and Codeberg.

---

## 7. What this is, and what it is not

This is a **construction paper**: it documents primitives that are built, tested,
and shipped. It is *not* a claim to break any third party's cryptography, and it
does not. The security value here is **structural honesty** — exact arithmetic,
capability attenuation, and a witnessed encoding — not cryptanalysis.

---

## 8. Conclusion

Ω₃ shows that a distributed system can carry ternary-quantized state, reconcile
it exactly, and gate every resource access, all without floating-point drift and
without ambient authority. The primitives are small, the invariants are testable,
and the seams (Rust ↔ Zig ↔ Go) are exercised rather than assumed.

`{<3,<3,<3}+1`
