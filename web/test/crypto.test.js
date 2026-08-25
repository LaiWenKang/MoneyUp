import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  WrongPassphraseError, createVault, decryptJSON, encryptJSON,
  fromBase64, rewrapVault, toBase64, unlockVault
} from '../src/crypto.js';

describe('vault', () => {
  it('round-trips a record through the derived key', async () => {
    const { envelope, dataKey } = await createVault('correct horse battery');
    const sealed = await encryptJSON(dataKey, { amount: '12.50', currency: 'SGD' });

    const reopened = await unlockVault(envelope, 'correct horse battery');
    assert.deepEqual(await decryptJSON(reopened, sealed), {
      amount: '12.50', currency: 'SGD'
    });
  });

  it('refuses the wrong passphrase instead of returning garbage', async () => {
    const { envelope } = await createVault('correct horse battery');
    await assert.rejects(
      () => unlockVault(envelope, 'incorrect horse battery'),
      WrongPassphraseError
    );
  });

  it('writes no plaintext into the stored envelope or ciphertext', async () => {
    const { envelope, dataKey } = await createVault('pass');
    const sealed = await encryptJSON(dataKey, { payee: 'Starbucks Orchard' });

    const envelopeText = JSON.stringify(envelope);
    assert.ok(!envelopeText.includes('pass'), 'passphrase must not be stored');
    const cipherText = new TextDecoder().decode(sealed.ciphertext);
    assert.ok(!cipherText.includes('Starbucks'), 'payee must not be readable');
  });

  it('changes the passphrase without touching stored records', async () => {
    const { envelope, dataKey } = await createVault('first');
    const sealed = await encryptJSON(dataKey, { note: 'unchanged' });

    const rewrapped = await rewrapVault(envelope, 'first', 'second');
    const reopened = await unlockVault(rewrapped, 'second');

    assert.deepEqual(await decryptJSON(reopened, sealed), { note: 'unchanged' });
    await assert.rejects(() => unlockVault(rewrapped, 'first'), WrongPassphraseError);
  });

  it('uses a fresh salt and IV for every vault', async () => {
    const first = await createVault('same');
    const second = await createVault('same');
    assert.notEqual(first.envelope.salt, second.envelope.salt);
    assert.notEqual(first.envelope.wrappedKey, second.envelope.wrappedKey);
  });

  it('round-trips base64 for the bytes it persists', () => {
    const bytes = new Uint8Array([0, 1, 127, 128, 255]);
    assert.deepEqual(fromBase64(toBase64(bytes)), bytes);
  });
});
