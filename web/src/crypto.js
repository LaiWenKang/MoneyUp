// Local encryption for the browser.
//
// The iOS app keeps a random 256-bit database key in the Keychain, released
// only on Face ID or passcode. A browser has no Keychain and no Secure
// Enclave, so the same random data key is instead wrapped with a key derived
// from a passphrase the user types. The data key is never stored unwrapped
// and never leaves this device.
//
// This is a weaker guarantee than the iOS one and the docs say so. It is not
// weaker than it needs to be: the derivation is deliberately slow, the
// unwrapped key is non-extractable, and it is dropped on lock.

const KDF_ITERATIONS = 600_000;
const SALT_BYTES = 16;
const IV_BYTES = 12;

const subtle = globalThis.crypto?.subtle;

function requireSubtle() {
  if (!subtle) {
    throw new Error(
      'This browser exposes no Web Crypto. MoneyUp will not store anything unencrypted.'
    );
  }
  return subtle;
}

function randomBytes(count) {
  return globalThis.crypto.getRandomValues(new Uint8Array(count));
}

export function toBase64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

async function deriveWrappingKey(passphrase, salt, iterations) {
  const material = await requireSubtle().importKey(
    'raw',
    new TextEncoder().encode(passphrase),
    'PBKDF2',
    false,
    ['deriveKey']
  );
  return requireSubtle().deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['wrapKey', 'unwrapKey']
  );
}

/**
 * Creates a fresh vault: a random data key, wrapped by the passphrase.
 * Returns the envelope to persist and the live key to hold in memory.
 */
export async function createVault(passphrase) {
  const salt = randomBytes(SALT_BYTES);
  const iv = randomBytes(IV_BYTES);
  const wrappingKey = await deriveWrappingKey(passphrase, salt, KDF_ITERATIONS);

  const dataKey = await requireSubtle().generateKey(
    { name: 'AES-GCM', length: 256 },
    true,
    ['encrypt', 'decrypt']
  );
  const wrapped = await requireSubtle().wrapKey('raw', dataKey, wrappingKey, {
    name: 'AES-GCM',
    iv
  });

  // Re-import non-extractable: nothing after setup should be able to read the
  // raw key back out, including our own code.
  const raw = await requireSubtle().exportKey('raw', dataKey);
  const sealed = await requireSubtle().importKey(
    'raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']
  );

  return {
    envelope: {
      version: 1,
      kdf: 'PBKDF2-SHA256',
      iterations: KDF_ITERATIONS,
      salt: toBase64(salt),
      iv: toBase64(iv),
      wrappedKey: toBase64(new Uint8Array(wrapped))
    },
    dataKey: sealed
  };
}

export class WrongPassphraseError extends Error {}

export async function unlockVault(envelope, passphrase) {
  const wrappingKey = await deriveWrappingKey(
    passphrase,
    fromBase64(envelope.salt),
    envelope.iterations
  );
  try {
    return await requireSubtle().unwrapKey(
      'raw',
      fromBase64(envelope.wrappedKey),
      wrappingKey,
      { name: 'AES-GCM', iv: fromBase64(envelope.iv) },
      { name: 'AES-GCM' },
      false,
      ['encrypt', 'decrypt']
    );
  } catch {
    // AES-GCM authentication failed, which for a wrapped key means only one
    // thing worth telling the user.
    throw new WrongPassphraseError('That passphrase does not open this data.');
  }
}

/** Changes the passphrase without re-encrypting a single record. */
export async function rewrapVault(envelope, currentPassphrase, nextPassphrase) {
  await unlockVault(envelope, currentPassphrase);
  const oldWrapping = await deriveWrappingKey(
    currentPassphrase, fromBase64(envelope.salt), envelope.iterations
  );
  const raw = await requireSubtle().unwrapKey(
    'raw', fromBase64(envelope.wrappedKey), oldWrapping,
    { name: 'AES-GCM', iv: fromBase64(envelope.iv) },
    { name: 'AES-GCM' }, true, ['encrypt', 'decrypt']
  );

  const salt = randomBytes(SALT_BYTES);
  const iv = randomBytes(IV_BYTES);
  const newWrapping = await deriveWrappingKey(nextPassphrase, salt, KDF_ITERATIONS);
  const wrapped = await requireSubtle().wrapKey('raw', raw, newWrapping, {
    name: 'AES-GCM', iv
  });

  return {
    ...envelope,
    iterations: KDF_ITERATIONS,
    salt: toBase64(salt),
    iv: toBase64(iv),
    wrappedKey: toBase64(new Uint8Array(wrapped))
  };
}

export async function encryptJSON(dataKey, value) {
  const iv = randomBytes(IV_BYTES);
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const ciphertext = await requireSubtle().encrypt(
    { name: 'AES-GCM', iv }, dataKey, plaintext
  );
  return { iv, ciphertext: new Uint8Array(ciphertext) };
}

export async function decryptJSON(dataKey, { iv, ciphertext }) {
  const plaintext = await requireSubtle().decrypt(
    { name: 'AES-GCM', iv }, dataKey, ciphertext
  );
  return JSON.parse(new TextDecoder().decode(plaintext));
}
