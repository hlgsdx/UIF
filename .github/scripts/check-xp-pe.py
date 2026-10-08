#!/usr/bin/env python3
"""Fail the XP artifact build on non-x86 PE, subsystem > 5.1 or clear bad imports.

This is a static compatibility gate, NOT proof of runtime compatibility.
"""
import pathlib
import struct
import sys

FORBIDDEN_DLLS = {
    'kernelbase.dll', 'ucrtbase.dll', 'vcruntime140.dll',
    'vcruntime140_1.dll', 'msvcp140.dll', 'd3d11.dll', 'dxgi.dll',
}
FORBIDDEN_IMPORTS = {
    'GetTickCount64', 'InitializeCriticalSectionEx', 'CreateFile2',
    'CancelIoEx', 'GetFinalPathNameByHandleA', 'GetFinalPathNameByHandleW',
    'GetFileInformationByHandleEx', 'GetThreadId', 'SetThreadDescription',
    'GetUserDefaultLocaleName', 'GetLocaleInfoEx', 'LCMapStringEx',
    'CompareStringEx', 'IsWow64Process2', 'VirtualAlloc2', 'GetSystemTimePreciseAsFileTime',
}


def check(path):
    data = path.read_bytes()

    def unpack(fmt, off):
        return struct.unpack_from(fmt, data, off)

    def cstr(off):
        end = data.index(b'\x00', off, min(len(data), off + 512))
        return data[off:end].decode('ascii', 'replace')

    if data[:2] != b'MZ':
        raise ValueError('not a DOS/PE image')
    pe = unpack('<I', 0x3C)[0]
    if data[pe:pe + 4] != b'PE\x00\x00':
        raise ValueError('PE signature absent')
    coff = pe + 4
    machine, nsections, _, _, _, opt_size, _ = unpack('<HHIIIHH', coff)
    opt = coff + 20
    magic = unpack('<H', opt)[0]
    if machine != 0x14C or magic != 0x10B:
        raise ValueError(f'expected PE32 x86, got machine={machine:#x}, magic={magic:#x}')
    osver = unpack('<HH', opt + 40)
    subver = unpack('<HH', opt + 48)
    if osver > (5, 1) or subver > (5, 1):
        raise ValueError(f'newer than XP: OS={osver}, subsystem={subver}')
    n_dirs = unpack('<I', opt + 92)[0]
    import_rva = unpack('<I', opt + 104)[0] if n_dirs > 1 else 0
    section_base = opt + opt_size
    sections = []
    for index in range(nsections):
        off = section_base + index * 40
        vsize, rva, raw_size, raw_ptr = unpack('<IIII', off + 8)
        sections.append((rva, max(vsize, raw_size), raw_ptr, raw_size))

    def to_offset(rva):
        for base, size, ptr, raw_size in sections:
            if base <= rva < base + size and rva - base < raw_size:
                return ptr + (rva - base)
        raise ValueError(f'RVA {rva:#x} not backed by file section')

    imports = []
    if import_rva:
        desc = to_offset(import_rva)
        for _ in range(2048):
            original, _, _, name_rva, thunk = unpack('<IIIII', desc)
            if not any((original, name_rva, thunk)):
                break
            dll = cstr(to_offset(name_rva)).lower()
            if (dll in FORBIDDEN_DLLS or dll.startswith('api-ms-win-')
                    or dll.startswith('ext-ms-') or dll.startswith('msvcp14')):
                raise ValueError(f'unsupported DLL dependency: {dll}')
            imports.append(dll)
            table = to_offset(original or thunk)
            for j in range(65536):
                ref = unpack('<I', table + 4 * j)[0]
                if ref == 0:
                    break
                if ref & 0x80000000:  # import by ordinal
                    continue
                symbol = cstr(to_offset(ref) + 2)
                if symbol in FORBIDDEN_IMPORTS:
                    raise ValueError(f'unsupported API: {dll}!{symbol}')
            else:
                raise ValueError('invalid import thunk table')
            desc += 20
        else:
            raise ValueError('invalid import directory')
    print(f'PASS {path.name}: OS {osver[0]}.{osver[1]}, '
          f'subsystem {subver[0]}.{subver[1]}, imports={sorted(set(imports))}')


def main():
    folder = pathlib.Path(sys.argv[1])
    binaries = sorted(folder.glob('*.dll'))
    if not binaries:
        raise SystemExit(f'No DLLs in {folder}')
    failures = []
    for binary in binaries:
        try:
            check(binary)
        except (ValueError, struct.error, IndexError) as exc:
            print(f'FAIL {binary.name}: {exc}', file=sys.stderr)
            failures.append(binary.name)
    if failures:
        raise SystemExit(f'Failed XP static checks: {", ".join(failures)}')
    print(f'All {len(binaries)} x86 XP-candidate DLLs passed static PE checks.')


if __name__ == '__main__':
    main()
