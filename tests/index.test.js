import { describe, it, expect } from 'vitest';
import { sestej } from '../src/index.js';

describe('sestej', () => {
  it('sesteje dve stevili', () => {
    expect(sestej(2, 3)).toBe(5);
  });
});
