import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

void main() {
  test('encodes each value by type', () {
    expect(
      buildFilter('a = {:s} && b = {:i} && c = {:d} && d = {:b} && e = {:n}',
          {'s': 'x', 'i': 3, 'd': 1.5, 'b': true, 'n': null}),
      'a = "x" && b = 3 && c = 1.5 && d = true && e = null',
    );
  });

  test('escapes quotes and backslashes in strings', () {
    expect(buildFilter('t ~ {:t}', {'t': r'a"b\c'}), r't ~ "a\"b\\c"');
  });

  test('dates are ISO 8601 UTC with milliseconds', () {
    final d = DateTime.utc(2026, 10, 24, 9, 5, 7, 42, 999);
    expect(buildFilter('c > {:d}', {'d': d}), 'c > "2026-10-24T09:05:07.042Z"');
  });

  test('lists and fields', () {
    expect(
        buildFilter('{:f} ?= {:l}', {
          'f': Field('meta.tag'),
          'l': ['a', 1]
        }),
        'meta.tag ?= ("a", 1)');
    expect(() => Field('a b'), throwsArgumentError);
    expect(() => Field('1a'), throwsArgumentError);
  });

  test('missing placeholders and unsupported values throw', () {
    expect(() => buildFilter('a = {:x}'), throwsArgumentError);
    expect(
        () => buildFilter('a = {:x}', {'x': double.nan}), throwsArgumentError);
    expect(() => buildFilter('a = {:x}', {'x': Object()}), throwsArgumentError);
  });

  test('text without placeholders is unchanged', () {
    expect(buildFilter('status = "published"'), 'status = "published"');
  });
}
