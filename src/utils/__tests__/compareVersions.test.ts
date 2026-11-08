import { compareVersions } from '../paths';

describe('compareVersions', () => {
  it('orders by major, minor, then patch', () => {
    expect(compareVersions('0.2.0', '0.3.0')).toBe(-1);
    expect(compareVersions('1.0.0', '0.9.9')).toBe(1);
    expect(compareVersions('0.2.10', '0.2.9')).toBe(1);
  });

  it('treats equal versions and prerelease suffixes as their numeric core', () => {
    expect(compareVersions('0.2.0', '0.2.0')).toBe(0);
    expect(compareVersions('0.3.0-beta.1', '0.3.0')).toBe(0);
  });

  it('reads missing or non-numeric parts as 0', () => {
    expect(compareVersions('1', '1.0.0')).toBe(0);
    expect(compareVersions('x.y.z', '0.0.1')).toBe(-1);
  });
});
