#!/usr/bin/env python3
"""Generate DirnexCore's DTS Coherent Acoustics tables from the ETSI specification.

Usage:
    curl -fsSLO https://www.etsi.org/deliver/etsi_ts/102100_102199/102114/01.02.01_60/ts_102114v010201p.pdf
    curl -fsSLO https://www.etsi.org/deliver/etsi_ts/102100_102199/102114/01.06.01_60/ts_102114v010601p.pdf
    python3 -I scripts/generate_dts_tables.py ts_102114v010201p.pdf ts_102114v010601p.pdf

ETSI TS 102 114 prints its tables in Annex D, and both editions are read, because neither is right on
its own and each checks the other:

- The Huffman code books (D.5) come from V1.2.1. V1.6.1 prints the same books apart from two faults:
  D65 stops at ±30, leaving out ±31 and ±32, and D129 prints its -37 row as "37". The script stops if
  the two editions differ anywhere else. Every book must also be a complete prefix code holding each
  quantization level once, which a misread row or a dropped digit breaks.
- The 32-band and LFE filters (D.8, and D.8 and D.9 in V1.2.1) agree between the editions to the
  digits both print, apart from the perfect-reconstruction filter, which V1.6.1 replaced in every tap
  (by up to 6e-6). V1.2.1's is kept: it is the one libavcodec carries, so it is the filter DTS streams
  have been played with.
- The scale factor, step size and joint intensity tables (D.1 to D.3) come from V1.6.1, checked against
  their own columns in decibels.

Neither edition prints the two vector-quantization code books (D.10), which the decoder takes from
elsewhere; see `DTSVectorTables`.

The block code books (D.6) are not copied: a block code is decoded arithmetically (Annex C.3.2).
"""

import hashlib
import json
import math
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = os.path.join(ROOT, 'DirnexCore/Sources/DirnexCore/Services')
LINES_TOOL = os.path.join(ROOT, 'scripts/pdf_lines.swift')
WIDTH = 100


def pdf_lines(path):
    result = subprocess.run(['xcrun', 'swift', LINES_TOOL, path], capture_output=True, text=True, check=True)
    return result.stdout.split('\n')


def pieces(line):
    """A row's pieces as (text, x); `None` for a line that is not a row of pieces."""
    out = []
    for part in line.split(' | '):
        match = re.match(r'^(.*)@(\d+)$', part)
        if not match:
            return None
        out.append((match.group(1), int(match.group(2))))
    return out


def section(lines, start, end):
    """The lines from the heading `start` to the heading `end`, passing over the table of contents."""
    def heading(line, text):
        return line.startswith(text) and '...' not in line
    first = next(i for i, line in enumerate(lines) if heading(line, start))
    last = next(i for i, line in enumerate(lines) if i > first and heading(line, end))
    return lines[first:last]


# MARK: - Huffman code books (D.5)

def huffman_books(lines):
    """Every code book in D.5 as {name: {level: (length, code)}}."""
    books = {}
    block = []            # the tables printed side by side, as (name, x), left to right
    rows_since_header = 0
    for line in section(lines, 'D.5 Huffman Code Books', 'D.6 Block Code Books'):
        row = pieces(line)
        if not row:
            continue
        text = ' '.join(t for t, _ in row)
        names = [(a + b, x) for t, x in row for a, b in re.findall(r'Table ([A-Z]+)\.?(\d+)', t)]
        if names:
            # A row of headers may come as one piece naming several tables, or a header per line.
            if len(names) > 1 and len({x for _, x in names}) == 1:
                names = [(name, x + i) for i, (name, x) in enumerate(names)]
            block = sorted(block + names if block and rows_since_header == 0 else names, key=lambda n: n[1])
            for name, _ in names:
                books[name] = {}
            rows_since_header = 0
            continue
        if re.search(r'[A-Za-z]', text) or not block:
            continue
        if len(row) == 1 and re.fullmatch(r'\d+', text) and 280 < row[0][1] < 300:
            continue  # the page number
        tokens = [token for t, _ in row for token in t.split()]
        starts = [x for t, x in row for _ in t.split()]
        triples = []
        i = 0
        while i < len(tokens):
            level, x = int(tokens[i]), starts[i]
            length = int(tokens[i + 1])
            code = tokens[i + 2]
            i += 3
            # ETSI writes 1379 as "1 379": a group of three digits after a code continues it. A level
            # is never three digits without a sign, so nothing else reads this way.
            while i < len(tokens) and re.fullmatch(r'\d{3}', tokens[i]):
                code += tokens[i]
                i += 1
            triples.append((level, length, int(code), x))
        rows_since_header += 1
        names_in_block = [name for name, _ in block]
        if len(names_in_block) == 1:
            targets = names_in_block * len(triples)
        elif len(triples) == len(names_in_block):
            targets = names_in_block
        else:
            # Tables side by side in bands of equal width across the page.
            count = len(names_in_block)
            band = lambda x: min(count - 1, max(0, int((x - 50) / (510 / count))))
            targets = [names_in_block[band(t[3])] for t in triples]
            if len(set(targets)) != len(targets):
                sys.exit(f'cannot tell the tables apart in row {line!r}')
        for name, (level, length, code, _) in zip(targets, triples):
            if level in books[name]:
                books[name].setdefault('_duplicates', []).append((level, length, code))
            else:
                books[name][level] = (length, code)
    return books


def check_book(name, book):
    """The reason `book` cannot be a code book, or `None`."""
    if '_duplicates' in book:
        return f'level printed twice: {book["_duplicates"]}'
    levels = sorted(book)
    if re.fullmatch(r'[A-D]4', name):
        span = range(0, 4)        # TMODE
    elif re.fullmatch(r'[A-E]12', name):
        span = range(1, 13)       # ABITS
    else:
        half = int(re.sub(r'\D', '', name)) // 2
        span = range(-half, half + 1)
    if levels != list(span):
        return f'levels {levels[0]}..{levels[-1]}, {len(levels)} of them'
    codes = sorted(format(code, f'0{length}b') for length, code in book.values() if code < (1 << length))
    if len(codes) != len(book):
        return 'a code longer than its length'
    for a, b in zip(codes, codes[1:]):
        if b.startswith(a):
            return f'{a} is a prefix of {b}'
    if sum(2.0 ** -length for length, _ in book.values()) != 1:
        return 'not a complete code (Kraft sum is not 1)'
    return None


def checked_books(old_lines, new_lines):
    old = huffman_books(old_lines)
    new = huffman_books(new_lines)
    for name, book in old.items():
        problem = check_book(name, book)
        if problem:
            sys.exit(f'V1.2.1 {name}: {problem}')
    if sorted(old) != sorted(new):
        sys.exit(f'the editions name different books: {sorted(set(old) ^ set(new))}')
    known = {
        ('D65', 31), ('D65', -31), ('D65', 32), ('D65', -32),  # left out of V1.6.1
        ('D129', 37), ('D129', -37),                           # V1.6.1 prints -37 as "37"
    }
    for name in old:
        new_book = {k: v for k, v in new[name].items() if k != '_duplicates'}
        for level in set(old[name]) | set(new_book):
            if old[name].get(level) != new_book.get(level) and (name, level) not in known:
                sys.exit(f'{name} level {level}: V1.2.1 {old[name].get(level)}, V1.6.1 {new_book.get(level)}')
    return old


# MARK: - Filters (D.8, and D.9 in V1.2.1)

def filters_old(lines):
    """V1.2.1 prints each filter in three columns a page, read down each column in turn."""
    headings = {
        'D.8.1 Perfect Reconstruction': 'perfect',
        'D.8.2 Non-Perfect Reconstruction': 'nonperfect',
        'D.9.1 64 x Interpolation': 'lfe64',
        'D.9.2 128 x Interpolation': 'lfe128',
        'D.10 VQ Tables': None,
    }
    number = re.compile(r'^[-+]?\d+\.\d+(E[-+]\d+)?$', re.I)
    out, current, chunk = {}, None, []

    def flush():
        if current and chunk:
            columns = {}
            for row in chunk:
                for value, x in row:
                    columns.setdefault(round(x / 40), []).append(value)
            for key in sorted(columns):
                out[current].extend(columns[key])
        chunk.clear()

    started = False
    for line in lines:
        if line.startswith('=====PAGE'):
            flush()
            continue
        row = pieces(line)
        if not row:
            continue
        head = row[0][0].strip()
        if head in headings:
            flush()
            current = headings[head]
            started = started or head.startswith('D.8.1')
            if current:
                out[current] = []
            continue
        if not started or not current:
            continue
        values = [(float(t), x) for t, x in row if number.match(t.strip())]
        if values and len(values) == len(row):
            chunk.append(values)
    flush()
    return out


def filters_new(lines):
    """V1.6.1 prints all four filters as one table: index, perfect, non-perfect, 64x, 128x."""
    number = r'-?\d+,\d+e[-+]\d+'
    rows = {}
    for line in section(lines, 'D.8@', 'D.9@'):
        row = pieces(line)
        if not row:
            continue
        text = ' '.join(t for t, _ in row)
        match = re.fullmatch(rf'(\d+) ({number}) ({number}) ({number}) ({number})', text.strip())
        if match:
            rows[int(match.group(1))] = [float(match.group(k).replace(',', '.')) for k in range(2, 6)]
    if sorted(rows) != list(range(512)):
        sys.exit('V1.6.1 D.8 does not have 512 rows')
    names = ['perfect', 'nonperfect', 'lfe64', 'lfe128']
    return {name: [rows[i][k] for i in range(512)] for k, name in enumerate(names)}


def checked_filters(old_lines, new_lines):
    old = filters_old(old_lines)
    new = filters_new(new_lines)
    for name in ('perfect', 'nonperfect', 'lfe64', 'lfe128'):
        if len(old.get(name, [])) != 512:
            sys.exit(f'V1.2.1 {name} has {len(old.get(name, []))} taps')
    for name in ('nonperfect', 'lfe64', 'lfe128'):
        for i, (a, b) in enumerate(zip(old[name], new[name])):
            # V1.6.1 prints ten significant digits.
            if abs(a - b) > 1e-9 * max(abs(a), abs(b), 1e-3):
                sys.exit(f'{name}[{i}]: V1.2.1 {a!r}, V1.6.1 {b!r}')
    if all(a == b for a, b in zip(old['perfect'], new['perfect'])):
        sys.exit('the editions now agree on the perfect-reconstruction filter: revisit the choice')
    return old


# MARK: - Scale factors, step sizes and joint intensity (D.1 to D.3)

def integer_pairs(lines, start, end, count):
    """(index, value) pairs from a table whose rows mix integers with decibel columns."""
    table = {}
    for line in section(lines, start, end):
        row = pieces(line)
        if not row:
            continue
        # Decimal columns (decibels, nominal sizes) are dropped; a row of words is not a row.
        tokens = [t for t in ' '.join(t for t, _ in row).split() if not re.fullmatch(r'-?\d+,\d+(e-?\d+)?', t)]
        if any(re.search(r'[A-Za-z]', t) and t != 'invalid' for t in tokens):
            continue
        values = [t for t in tokens if re.fullmatch(r'\d+|invalid', t)]
        for index, value in zip(values[::2], values[1::2]):
            table[int(index)] = 0 if value == 'invalid' else int(value)
    if sorted(table) != list(range(count)):
        sys.exit(f'{start}: indexes {sorted(table)}')
    return [table[i] for i in range(count)]


def small_tables(lines):
    scale6 = integer_pairs(lines, 'D.1.1@', 'D.1.2@', 64)
    scale7 = integer_pairs(lines, 'D.1.2@', 'D.2 Quantization', 128)
    lossy = integer_pairs(lines, 'D.2.1 Lossy', 'D.2.2 Lossless', 32)
    lossless = integer_pairs(lines, 'D.2.2 Lossless', 'D.3@', 32)
    joint = {}
    for line in section(lines, 'D.3@', 'D.4 Dynamic'):
        row = pieces(line)
        if not row:
            continue
        tokens = ' '.join(t for t, _ in row).split()
        if any(re.search(r'[A-Za-z]', t) for t in tokens):
            continue
        for index, value in zip(tokens[::2], tokens[1::2]):
            joint[int(index)] = float(value.replace(',', '.'))
    if sorted(joint) != list(range(129)):
        sys.exit(f'D.3: indexes {sorted(joint)}')
    joint = [joint[i] for i in range(129)]
    # Each table against what its other columns say it is.
    for name, table, last in (('6-bit', scale6, 62), ('7-bit', scale7, 124)):
        valid = table[:last + 1]
        if valid[0] != 1 or valid[-1] != 8317638 or any(table[last + 1:]):
            sys.exit(f'{name} scale factors misread at an end')
        if any(b < a for a, b in zip(valid, valid[1:])):
            sys.exit(f'{name} scale factors do not rise')
        # The last half of each table rises by its nominal step, which a dropped digit breaks.
        step = 2.2 if name == '6-bit' else 1.1
        for i in range(last // 2, last):
            if abs(20 * math.log10(valid[i + 1] / valid[i]) - step) > 0.05:
                sys.exit(f'{name} scale factor {i + 1} = {valid[i + 1]} is not {step} dB above {valid[i]}')
    if lossy[1] != 6710886 or lossy[26] != 21 or lossless[26] != 1:
        sys.exit('step sizes misread')
    for i, value in enumerate(joint):
        expected = 10 ** ((i - 64) * 0.5 / 20)
        if abs(value / expected - 1) > 0.01:
            sys.exit(f'joint scale {i} = {value}, expected about {expected}')
    return scale6, scale7, lossy, lossless, joint


# MARK: - Output

def wrapped(values, indent='        '):
    """`values` comma-separated in lines of at most WIDTH, with no comma after the last, as SwiftFormat's
    `trailingCommas` rule wants them under `--commas inline`."""
    lines, current = [], ''
    values = list(values)
    for index, value in enumerate(values):
        piece = f'{value},' if index < len(values) - 1 else f'{value}'
        candidate = f'{current} {piece}' if current else piece
        if len(indent) + len(candidate) > WIDTH and current:
            lines.append(indent + current)
            current = piece
        else:
            current = candidate
    if current:
        lines.append(indent + current)
    return '\n'.join(lines)


def float_literal(value):
    return f'{value:.10e}'.replace('e-0', 'e-').replace('e+0', 'e').replace('e+', 'e')


def header(sources):
    lines = ['// Generated by scripts/generate_dts_tables.py from ETSI TS 102 114, Annex D:']
    for name, digest in sources:
        lines.append(f'// {name}, sha256 {digest}.')
    lines.append('// Do not edit by hand: run the script again.')
    return '\n'.join(lines) + '\n'


def write(name, text):
    with open(os.path.join(SERVICES, name), 'w') as out:
        out.write(text)


def main():
    old_path, new_path = sys.argv[1], sys.argv[2]
    sources = []
    for path in (old_path, new_path):
        sources.append((os.path.basename(path), hashlib.sha256(open(path, 'rb').read()).hexdigest()))
    old_lines = pdf_lines(old_path)
    new_lines = pdf_lines(new_path)
    if not any('V1.2.1' in line for line in old_lines[:40]) or not any('V1.6.1' in line for line in new_lines[:40]):
        sys.exit('give V1.2.1 first and V1.6.1 second')

    books = checked_books(old_lines, new_lines)
    filters = checked_filters(old_lines, new_lines)
    scale6, scale7, lossy, lossless, joint = small_tables(new_lines)

    # Two files, each under SwiftLint's file_length: the books of up to 65 levels, and the 129-level ones.
    order = sorted(books, key=lambda n: (int(re.sub(r'\D', '', n)), n))
    for file_name, property_name, names, doc in (
        ('DTSHuffmanTables.swift', 'huffman', [n for n in order if not n.endswith('129')],
         'The Huffman code books of Annex D.5 of up to 65 levels'),
        ('DTSHuffmanTables129.swift', 'huffman129', [n for n in order if n.endswith('129')],
         'The 129-level Huffman code books of Annex D.5, for scale factors and for `ABITS` 10'),
    ):
        text = header(sources[:1]) + '\n'
        text += 'extension DTSTables {\n'
        text += f'    /// {doc}, by name, each a run of (level, length, code)\n'
        text += '    /// triples.\n'
        text += f'    static let {property_name}: [String: [Int32]] = [\n'
        for position, name in enumerate(names):
            triples = []
            for level in sorted(books[name], key=lambda v: (abs(v), -v)):
                length, code = books[name][level]
                triples += [level, length, code]
            comma = ',' if position < len(names) - 1 else ''
            text += f'        "{name}": [\n{wrapped(triples, "            ")}\n        ]{comma}\n'
        text += '    ]\n}\n'
        write(file_name, text)

    text = header(sources) + '\n'
    text += 'extension DTSTables {\n'
    docs = {
        'perfect': 'The 32-band synthesis filter for perfect reconstruction (`FILTS` 1), from V1.2.1.',
        'nonperfect': 'The 32-band synthesis filter for non-perfect reconstruction (`FILTS` 0).',
        'lfe64': 'The LFE interpolation filter for 64 times (`LFF` 2).',
        'lfe128': 'The LFE interpolation filter for 128 times (`LFF` 1).',
    }
    names = {'perfect': 'perfectFilter', 'nonperfect': 'nonPerfectFilter', 'lfe64': 'lfeFilter64',
             'lfe128': 'lfeFilter128'}
    for key in ('perfect', 'nonperfect', 'lfe64', 'lfe128'):
        text += f'    /// {docs[key]}\n'
        text += f'    static let {names[key]}: [Float] = [\n{wrapped([float_literal(v) for v in filters[key]])}\n    ]\n'
        if key != 'lfe128':
            text += '\n'
    text += '}\n'
    write('DTSFilterTables.swift', text)

    text = header(sources[1:]) + '\n'
    text += 'extension DTSTables {\n'
    text += '    /// The 6-bit scale factors (D.1.1), as integers; index 63 is invalid.\n'
    text += f'    static let scaleFactors6: [Int32] = [\n{wrapped(scale6)}\n    ]\n\n'
    text += '    /// The 7-bit scale factors (D.1.2), as integers; indexes 125 to 127 are invalid.\n'
    text += f'    static let scaleFactors7: [Int32] = [\n{wrapped(scale7)}\n    ]\n\n'
    text += '    /// The lossy quantizer step sizes by `ABITS` (D.2.1), times 2^22; 27 and up are invalid.\n'
    text += f'    static let lossyStepSizes: [Int32] = [\n{wrapped(lossy)}\n    ]\n\n'
    text += '    /// The lossless quantizer step sizes by `ABITS` (D.2.2), times 2^22; 27 and up are invalid.\n'
    text += f'    static let losslessStepSizes: [Int32] = [\n{wrapped(lossless)}\n    ]\n\n'
    text += '    /// The joint intensity scale factors (D.3), by index from 0 to 128.\n'
    text += f'    static let jointScales: [Float] = [\n{wrapped([repr(v) for v in joint])}\n    ]\n'
    text += '}\n'
    write('DTSQuantizerTables.swift', text)
    print(f'{len(books)} code books, 4 filters, 5 small tables')


if __name__ == '__main__':
    main()
