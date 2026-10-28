/**
 * 115 私有加密协议（m115）。
 *
 * 请求体格式：base64(RSA( 16字节随机key + XOR/反转后的 JSON ))
 * 响应体同样结构，但解码时用的是响应自带的前 16 字节作为种子。
 *
 * 协议来源：115driver (github.com/SheltonZhu/115driver) 的 pkg/crypto/m115。
 */
import { randomBytes } from 'node:crypto'

const N = BigInt(
  '0x8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021' +
    '36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633' +
    '8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1' +
    '0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683',
)
const E = 0x10001n
const KEY_LENGTH = 128 // 1024 bit

const XOR_KEY_SEED = Buffer.from([
  0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d,
  0xa6, 0x73, 0xb8, 0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64,
  0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa, 0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c,
  0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6, 0x2a, 0x96, 0x68, 0x18,
  0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7, 0x6c,
  0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe,
  0x7e, 0x86, 0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b,
  0x9c, 0x7e, 0x9d, 0x7a, 0x81, 0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
  0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48, 0xb9, 0xd5, 0x81, 0x9c, 0xf8,
  0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e, 0x36, 0x9f,
  0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8,
  0xf5,
])

const XOR_CLIENT_KEY = Buffer.from([
  0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46,
])

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n
  let b = base % mod
  let e = exp
  while (e > 0n) {
    if (e & 1n) result = (result * b) % mod
    b = (b * b) % mod
    e >>= 1n
  }
  return result
}

function bytesToBigInt(buf: Buffer): bigint {
  if (buf.length === 0) return 0n
  return BigInt('0x' + buf.toString('hex'))
}

function bigIntToBytes(value: bigint, length: number): Buffer {
  const hex = value.toString(16)
  const padded = hex.length >= length * 2 ? hex.slice(-length * 2) : hex.padStart(length * 2, '0')
  return Buffer.from(padded, 'hex')
}

function rsaEncryptSlice(input: Buffer): Buffer {
  const padSize = KEY_LENGTH - input.length - 3
  const buf = Buffer.alloc(KEY_LENGTH)
  buf[0] = 0
  buf[1] = 2
  for (let i = 0; i < padSize; i++) {
    // 对应 Go 的 b%0xff + 0x01，保证填充字节非零
    buf[2 + i] = (randomBytes(1)[0]! % 0xff) + 0x01
  }
  buf[padSize + 2] = 0
  input.copy(buf, padSize + 3)
  return bigIntToBytes(modPow(bytesToBigInt(buf), E, N), KEY_LENGTH)
}

function rsaEncrypt(input: Buffer): Buffer {
  const chunks: Buffer[] = []
  const sliceSize = KEY_LENGTH - 11
  for (let offset = 0; offset < input.length; offset += sliceSize) {
    chunks.push(rsaEncryptSlice(input.subarray(offset, offset + sliceSize)))
  }
  return Buffer.concat(chunks)
}

function rsaDecrypt(input: Buffer): Buffer {
  const chunks: Buffer[] = []
  for (let offset = 0; offset < input.length; offset += KEY_LENGTH) {
    const slice = input.subarray(offset, offset + KEY_LENGTH)
    const ret = bigIntToBytes(modPow(bytesToBigInt(slice), E, N), KEY_LENGTH)
    // 去掉前导 0x00 02 ... 00 填充
    let start = ret.length
    for (let i = 0; i < ret.length; i++) {
      if (ret[i] === 0 && i !== 0) {
        start = i + 1
        break
      }
    }
    chunks.push(ret.subarray(start))
  }
  return Buffer.concat(chunks)
}

function xorDeriveKey(seed: Buffer, size: number): Buffer {
  const key = Buffer.alloc(size)
  for (let i = 0; i < size; i++) {
    key[i] = (seed[i]! + XOR_KEY_SEED[size * i]!) & 0xff
    key[i] = key[i]! ^ XOR_KEY_SEED[size * (size - i - 1)]!
  }
  return key
}

function xorTransform(data: Buffer, key: Buffer): void {
  const mod = data.length % 4
  for (let i = 0; i < mod; i++) {
    data[i] = data[i]! ^ key[i % key.length]!
  }
  for (let i = mod; i < data.length; i++) {
    data[i] = data[i]! ^ key[(i - mod) % key.length]!
  }
}

function reverseBytes(data: Buffer): void {
  for (let i = 0, j = data.length - 1; i < j; i++, j--) {
    const tmp = data[i]!
    data[i] = data[j]!
    data[j] = tmp
  }
}

export function generateKey(): Buffer {
  return randomBytes(16)
}

export function encode(input: Buffer, key: Buffer): string {
  const buf = Buffer.concat([key, input])
  const body = buf.subarray(16)
  xorTransform(body, xorDeriveKey(key, 4))
  reverseBytes(body)
  xorTransform(body, XOR_CLIENT_KEY)
  return rsaEncrypt(buf).toString('base64')
}

export function decode(input: string, key: Buffer): Buffer {
  const data = rsaDecrypt(Buffer.from(input, 'base64'))
  const seed = data.subarray(0, 16)
  const output = Buffer.from(data.subarray(16))
  xorTransform(output, xorDeriveKey(seed, 12))
  reverseBytes(output)
  xorTransform(output, xorDeriveKey(key, 4))
  return output
}
