import { readFileSync, writeFileSync } from 'node:fs';
import { deflateSync, inflateSync } from 'node:zlib';

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const RUNTIME_LUT = new URL(
  '../android/src/main/res/raw/lut_looks.png',
  import.meta.url
);

function parsePng(path) {
  const png = readFileSync(path);
  if (!png.subarray(0, 8).equals(SIGNATURE)) throw new Error('invalid PNG signature');

  let offset = 8;
  let width;
  let height;
  const idat = [];
  const ancillary = [];
  while (offset < png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('ascii', offset + 4, offset + 8);
    const data = png.subarray(offset + 8, offset + 8 + length);
    offset += length + 12;
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      if (data[8] !== 8 || data[9] !== 2 || data[12] !== 0) {
        throw new Error('LUT must be non-interlaced RGB8');
      }
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type !== 'IEND') {
      ancillary.push(type);
    }
  }

  const packed = inflateSync(Buffer.concat(idat));
  const stride = width * 3;
  const pixels = Buffer.alloc(stride * height);
  let source = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = packed[source++];
    const row = pixels.subarray(y * stride, (y + 1) * stride);
    const previous =
      y === 0 ? Buffer.alloc(stride) : pixels.subarray((y - 1) * stride, y * stride);
    for (let x = 0; x < stride; x += 1) {
      const raw = packed[source++];
      const left = x >= 3 ? row[x - 3] : 0;
      const up = previous[x];
      const upperLeft = x >= 3 ? previous[x - 3] : 0;
      if (filter === 0) row[x] = raw;
      else if (filter === 1) row[x] = raw + left;
      else if (filter === 2) row[x] = raw + up;
      else if (filter === 3) row[x] = raw + Math.floor((left + up) / 2);
      else if (filter === 4) row[x] = raw + paeth(left, up, upperLeft);
      else throw new Error(`unsupported PNG filter ${filter}`);
    }
  }
  return { width, height, pixels, ancillary };
}

function paeth(left, up, upperLeft) {
  const estimate = left + up - upperLeft;
  const dl = Math.abs(estimate - left);
  const du = Math.abs(estimate - up);
  const dul = Math.abs(estimate - upperLeft);
  return dl <= du && dl <= dul ? left : du <= dul ? up : upperLeft;
}

function chunk(type, data) {
  const name = Buffer.from(type);
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length, 0);
  name.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(crc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}

function crc32(data) {
  let crc = 0xffffffff;
  for (const value of data) {
    crc ^= value;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function writePng(path, width, height, pixels) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  writeFileSync(
    path,
    Buffer.concat([
      SIGNATURE,
      chunk('IHDR', ihdr),
      chunk('IDAT', deflateSync(raw, { level: 9 })),
      chunk('IEND', Buffer.alloc(0)),
    ])
  );
}

function pixel(lut, look, r, g, b) {
  const n = 32;
  const x = (b % 8) * n + r;
  const y = (look * 4 + Math.floor(b / 8)) * n + g;
  const offset = (y * lut.width + x) * 3;
  return [lut.pixels[offset], lut.pixels[offset + 1], lut.pixels[offset + 2]];
}

function verify(path) {
  const lut = parsePng(path);
  if (lut.width !== 256 || lut.height !== 256) {
    throw new Error(`expected 256x256 atlas, got ${lut.width}x${lut.height}`);
  }
  if (lut.ancillary.some((type) => ['iCCP', 'sRGB', 'gAMA', 'cHRM'].includes(type))) {
    throw new Error(`color-profile chunk found: ${lut.ancillary.join(', ')}`);
  }

  for (let look = 0; look < 2; look += 1) {
    let previous = -1;
    for (let i = 0; i < 32; i += 1) {
      const [r, g, b] = pixel(lut, look, i, i, i);
      const luma = 0.299 * r + 0.587 * g + 0.114 * b;
      if (luma < previous) throw new Error(`look ${look} reverses grey ramp at ${i}`);
      previous = luma;
    }
  }
  console.log(`beauty LUT OK: ${lut.width}x${lut.height}, RGB8, Bright+Cool`);
}

function repackLegacy(input, output) {
  const legacy = parsePng(input);
  if (legacy.width !== 256 || legacy.height !== 384) {
    throw new Error('legacy atlas must be 256x384');
  }
  const rowBytes = legacy.width * 3;
  const pixels = legacy.pixels.subarray(rowBytes * 128);
  writePng(output, 256, 256, pixels);
  verify(output);
}

if (process.argv[2] === '--repack-legacy') {
  if (!process.argv[3]) throw new Error('usage: --repack-legacy INPUT [OUTPUT]');
  repackLegacy(process.argv[3], process.argv[4] ?? RUNTIME_LUT);
} else {
  verify(process.argv[2] ?? RUNTIME_LUT);
}
