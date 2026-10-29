"""Shared deterministic sample layout; no Azure or application dependencies."""

MAX_BYTES = 10_000_000_000
CONTROL_CONTAINER = "drtest"
CONTROL_BLOB = "_sample_upload.json"
LEASE_SECONDS = 60
RENEW_SECONDS = 15
GIB = 1024**3
MIB = 1024**2


def _integer(value):
    if isinstance(value, bool):
        raise ValueError("Sample sizes/count must be integers")
    text = str(value)
    if not text.isascii() or not text.isdecimal():
        raise ValueError("Sample sizes/count must be nonnegative integers")
    return int(text)


def layout(size_gb, large_gb, small_count, small_mb):
    """GiB/MiB inputs, with an immutable decimal 10 GB total ceiling."""
    size_gb, large_gb, small_count, small_mb = map(
        _integer, (size_gb, large_gb, small_count, small_mb)
    )
    size = min(size_gb * GIB, MAX_BYTES)
    large, small = large_gb * GIB, small_mb * MIB
    if min(size, large, small) <= 0:
        raise ValueError("Sample sizes must be positive")
    remaining = size - small_count * small
    if remaining < large:
        raise ValueError("Budget must fit all small files and at least one full large file")
    count, remainder = divmod(remaining, large)
    result = {f"large/large-{i:06d}.bin": large for i in range(count)}
    if remainder:
        result[f"large/large-{count:06d}.bin"] = remainder
    result.update({f"small/small-{i:06d}.bin": small for i in range(small_count)})
    return result
