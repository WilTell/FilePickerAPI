"""Правка ресурсов exe и DLL до подписи: кандидат для дымовой проверки.

Задача 1.6: у копии папки сборки должна быть другая версия файлов.
UpdateResource есть в pywin32, отдельная утилита не нужна.

    patch_resources.py <файл> --version 1.0.1
    patch_resources.py <файл> --marker 5100
"""

import argparse
import struct

import win32api
import win32con

SIGNATURE = struct.pack("<I", 0xFEEF04BD)
MARKER_NAME = "PROBEMARKER"


def bumped(data: bytes, version: str) -> bytes:
    """Вернуть VERSIONINFO с новой версией в VS_FIXEDFILEINFO."""
    numbers = [*map(int, version.split(".")), 0, 0, 0][:4]
    most = numbers[0] << 16 | numbers[1]
    least = numbers[2] << 16 | numbers[3]
    start = data.index(SIGNATURE) + 8
    packed = struct.pack("<IIII", most, least, most, least)
    return data[:start] + packed + data[start + len(packed) :]


def main() -> None:
    """Применить правки к файлу."""
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--version")
    parser.add_argument("--marker")
    args = parser.parse_args()

    module = win32api.LoadLibraryEx(args.path, 0, win32con.LOAD_LIBRARY_AS_DATAFILE)
    language = win32api.EnumResourceLanguages(module, win32con.RT_VERSION, 1)[0]
    data = win32api.LoadResource(module, win32con.RT_VERSION, 1, language)
    win32api.FreeLibrary(module)

    update = win32api.BeginUpdateResource(args.path, 0)
    if args.version:
        win32api.UpdateResource(
            update, win32con.RT_VERSION, 1, bumped(data, args.version), language
        )
    if args.marker:
        win32api.UpdateResource(
            update, win32con.RT_RCDATA, MARKER_NAME, args.marker.encode(), language
        )
    win32api.EndUpdateResource(update, 0)


if __name__ == "__main__":
    main()
