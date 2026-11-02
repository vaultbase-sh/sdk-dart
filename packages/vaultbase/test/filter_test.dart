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

  test('doubles are plain decimals, never exponents', () {
    String f(double d) => buildFilter('n = {:n}', {'n': d});
    expect(f(1e21), 'n = 1000000000000000000000');
    expect(f(-1.5e22), 'n = -15000000000000000000000');
    expect(f(1e-7), 'n = 0.0000001');
    expect(f(-2.5e-8), 'n = -0.000000025');
    expect(f(1.5), 'n = 1.5');
    expect(f(100.0), 'n = 100.0');
  });

  test('lists throw: the filter language has no list value', () {
    expect(
        () => buildFilter('t ?= {:l}', {
              'l': ['a', 1]
            }),
        throwsA(isA<ArgumentError>()
            .having((e) => '${e.message}', 'message', contains('||'))));
  });

  test('fields', () {
    expect(buildFilter('{:f} = 1', {'f': Field('meta.tag')}), 'meta.tag = 1');
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
