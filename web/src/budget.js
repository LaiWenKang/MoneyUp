// Arbitrary-depth budget hierarchy with roll-up, mirroring BudgetTree.swift.
//
// Limits belong to individual nodes. A parent limit caps all descendant
// spending; child limits are allocations inside it and are never summed into
// the parent's limit.

import { Money, ValidationError } from './domain.js';

export class BudgetTree {
  #nodesByID;

  constructor(currency, nodes) {
    this.currency = currency;
    this.nodes = nodes;
    this.#nodesByID = new Map();

    for (const node of nodes) {
      if (this.#nodesByID.has(node.id)) {
        throw new ValidationError(`Duplicate budget node: ${node.id}`);
      }
      if (node.limit) {
        if (node.limit.currency !== currency) {
          throw new ValidationError(
            `Limit on ${node.name} is in ${node.limit.currency}, not ${currency}`
          );
        }
        if (node.limit.isNegative) {
          throw new ValidationError(`Limit on ${node.name} is negative.`);
        }
      }
      this.#nodesByID.set(node.id, node);
    }

    for (const node of nodes) {
      if (node.parentID && !this.#nodesByID.has(node.parentID)) {
        throw new ValidationError(`${node.name} has a missing parent.`);
      }
    }
    this.#requireAcyclic();
  }

  #requireAcyclic() {
    for (const node of this.nodes) {
      const visited = new Set();
      let current = node.id;
      while (current) {
        if (visited.has(current)) {
          throw new ValidationError(`Budget hierarchy contains a cycle at ${current}`);
        }
        visited.add(current);
        current = this.#nodesByID.get(current)?.parentID ?? null;
      }
    }
  }

  /**
   * Rolls spending recorded against a node into that node and every ancestor.
   * Negative values are allowed, so a refund reduces the roll-up.
   */
  rolledUpSpending(directSpending) {
    const totals = new Map(this.nodes.map((node) => [node.id, 0n]));

    for (const [nodeID, money] of directSpending) {
      if (!this.#nodesByID.has(nodeID)) continue;
      if (money.currency !== this.currency) {
        throw new ValidationError(
          `Spending on ${nodeID} is in ${money.currency}, not ${this.currency}`
        );
      }
      let current = nodeID;
      while (current) {
        totals.set(current, (totals.get(current) ?? 0n) + money.units);
        current = this.#nodesByID.get(current)?.parentID ?? null;
      }
    }

    return new Map(
      [...totals].map(([id, units]) => [id, new Money(units, this.currency)])
    );
  }

  progress(directSpending) {
    const totals = this.rolledUpSpending(directSpending);
    return this.nodes.map((node) => {
      const spent = totals.get(node.id) ?? Money.zero(this.currency);
      return {
        node,
        spent,
        remaining: node.limit ? node.limit.subtract(spent) : null
      };
    });
  }
}

export function budgetNode({ id, parentID = null, name, limit = null }) {
  return { id, parentID, name, limit };
}
