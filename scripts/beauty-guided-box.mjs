import assert from 'node:assert/strict';

const values = Array.from({ length: 37 }, (_, i) => ((i * 73 + 19) % 101) / 100);
const clamp = (i) => values[Math.max(0, Math.min(values.length - 1, i))];
const linear = (x) => {
  const lo = Math.floor(x);
  const mix = x - lo;
  return clamp(lo) * (1 - mix) + clamp(lo + 1) * mix;
};

for (let center = 0; center < values.length; center += 1) {
  let nineTap = 0;
  for (let offset = -4; offset <= 4; offset += 1) {
    nineTap += clamp(center + offset);
  }
  const fiveTap =
    values[center] +
    2 * linear(center - 3.5) +
    2 * linear(center - 1.5) +
    2 * linear(center + 1.5) +
    2 * linear(center + 3.5);
  assert.ok(Math.abs(nineTap - fiveTap) < 1e-12, `box mismatch at ${center}`);
}

console.log('guided coefficient box OK: five bilinear reads equal nine taps');
