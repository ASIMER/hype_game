## Shared deterministic seed-hash for ALL procedural builders (terrain / flora /
## buildings). ONE copy of the math: co-op peers rebuild identical worlds because every
## system hashes identically — this used to be three byte-identical per-file copies,
## which is exactly the "edit one, desync the others" trap (docs/AUDIT.md F1).
## ANY change here changes every procedurally-built world: verify with the golden
## snapshot (tools/lint/check_golden.py) before committing.
class_name ProcHash


## Cheap deterministic positive hash of an int → big positive int.
static func h(n: int) -> int:
	var x: int = (n * 2654435761) ^ 0x27d4eb2d
	x = (x ^ (x >> 15)) * 0x85ebca6b
	x = x ^ (x >> 13)
	return abs(x)


## Deterministic float in [0,1) from seed `n`.
static func hf(n: int) -> float:
	return float(h(n) % 100000) / 100000.0


## Deterministic float in [lo,hi) from seed `n`.
static func hrange(n: int, lo: float, hi: float) -> float:
	return lo + hf(n) * (hi - lo)
