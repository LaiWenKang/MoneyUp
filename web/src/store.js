// Encrypted record store on IndexedDB.
//
// Every record is encrypted individually with AES-GCM under the vault's data
// key, so nothing readable is ever written to disk. The database holds the
// key envelope and ciphertext; opening it without the passphrase yields
// nothing but opaque bytes.

import { decryptJSON, encryptJSON } from './crypto.js';

const DB_NAME = 'moneyup';
const DB_VERSION = 1;
const RECORDS = 'records';
const META = 'meta';
const ENVELOPE_KEY = 'vault';

export const COLLECTIONS = {
  profile: 'profile',
  accounts: 'accounts',
  journalEntries: 'journal_entries',
  budgetNodes: 'budget_nodes'
};

function request(source) {
  return new Promise((resolve, reject) => {
    source.onsuccess = () => resolve(source.result);
    source.onerror = () => reject(source.error);
  });
}

export async function openDatabase() {
  if (!globalThis.indexedDB) {
    throw new Error('This browser has no IndexedDB, so there is nowhere safe to store data.');
  }
  const opening = indexedDB.open(DB_NAME, DB_VERSION);
  opening.onupgradeneeded = () => {
    const db = opening.result;
    if (!db.objectStoreNames.contains(RECORDS)) {
      db.createObjectStore(RECORDS, { keyPath: ['collection', 'id'] });
    }
    if (!db.objectStoreNames.contains(META)) {
      db.createObjectStore(META);
    }
  };
  return request(opening);
}

export async function loadEnvelope(db) {
  const tx = db.transaction(META, 'readonly');
  return (await request(tx.objectStore(META).get(ENVELOPE_KEY))) ?? null;
}

export async function saveEnvelope(db, envelope) {
  const tx = db.transaction(META, 'readwrite');
  tx.objectStore(META).put(envelope, ENVELOPE_KEY);
  return transactionDone(tx);
}

function transactionDone(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

export class EncryptedStore {
  #db;
  #dataKey;

  constructor(db, dataKey) {
    this.#db = db;
    this.#dataKey = dataKey;
  }

  /** All writes in one transaction, so a failure leaves nothing half-applied. */
  async write(records) {
    const sealed = await Promise.all(
      records.map(async ({ collection, id, value }) => ({
        collection,
        id,
        ...(await encryptJSON(this.#dataKey, value)),
        updatedAt: Date.now()
      }))
    );
    const tx = this.#db.transaction(RECORDS, 'readwrite');
    const store = tx.objectStore(RECORDS);
    for (const record of sealed) store.put(record);
    return transactionDone(tx);
  }

  async put(collection, id, value) {
    return this.write([{ collection, id, value }]);
  }

  async remove(collection, id) {
    const tx = this.#db.transaction(RECORDS, 'readwrite');
    tx.objectStore(RECORDS).delete([collection, id]);
    return transactionDone(tx);
  }

  async all(collection) {
    const tx = this.#db.transaction(RECORDS, 'readonly');
    const range = IDBKeyRange.bound([collection, ''], [collection, '￿']);
    const rows = await request(tx.objectStore(RECORDS).getAll(range));
    return Promise.all(rows.map((row) => decryptJSON(this.#dataKey, row)));
  }

  async get(collection, id) {
    const tx = this.#db.transaction(RECORDS, 'readonly');
    const row = await request(tx.objectStore(RECORDS).get([collection, id]));
    return row ? decryptJSON(this.#dataKey, row) : null;
  }

  /** Destroys everything, including the key envelope. Not recoverable. */
  async eraseEverything() {
    const tx = this.#db.transaction([RECORDS, META], 'readwrite');
    tx.objectStore(RECORDS).clear();
    tx.objectStore(META).clear();
    return transactionDone(tx);
  }
}
